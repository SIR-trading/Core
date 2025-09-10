#!/usr/bin/env node

// Node 18+ has fetch. Add crypto if missing.
if (!globalThis.crypto) globalThis.crypto = require("node:crypto").webcrypto;

const TransportNodeHid = require("@ledgerhq/hw-transport-node-hid").default;
const Eth = require("@ledgerhq/hw-app-eth").default;
const { ethers, TypedDataEncoder, Signature } = require("ethers");

// Import the low-level signer
const { signL1Action } = require("@nktkas/hyperliquid/signing");

// Helper: POST JSON using global fetch
async function postJson(url, body) {
    const res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body)
    });
    return { status: res.status, text: await res.text() };
}

// Build a Ledger wallet adapter that supports both personal_sign and EIP-712
function makeLedgerWalletAdapter({ eth, hdPath, address }) {
    const addr = address.toLowerCase();

    async function normalizeLedgerSig(sig) {
        let v = typeof sig.v === "string" ? parseInt(sig.v, 16) : sig.v;
        if (v >= 35) v = 27 + (v % 2);
        if (v === 0 || v === 1) v = 27 + v;
        const flat = "0x" + sig.r + sig.s + v.toString(16).padStart(2, "0");
        return { flat, v };
    }

    return {
        address: addr,

        // Called for L1 actions that use EIP-191 (personal_sign) over canonical bytes
        async signMessage(messageBytes) {
            const hex = Buffer.from(messageBytes).toString("hex");
            const sig = await eth.signPersonalMessage(hdPath, hex);
            const { flat } = await normalizeLedgerSig(sig);
            return flat; // 0x{r}{s}{v}
        },

        // Some SDK paths request typed-data. Implement via Ledger’s EIP-712.
        // Input shape expected by the SDK:
        // { domain, types, message } (EIP-712 v4)
        async signTypedData({ domain, types, message }) {
            // ethers v6 helpers to compute the two hashes Ledger expects
            // domainSeparator = keccak256(encodeDomain(domain))
            // messageHash     = keccak256(encodeData(primaryType, message))
            const encoder = TypedDataEncoder.from(types);
            const domainSeparator = TypedDataEncoder.hashDomain(domain);
            const messageHash = encoder.hash(message);

            // Ledger needs the two 32-byte hashes (no 0x) separately
            const sig = await eth.signEIP712HashedMessage(hdPath, domainSeparator.slice(2), messageHash.slice(2));
            const { flat } = await normalizeLedgerSig(sig);
            return flat; // 0x{r}{s}{v}
        }
    };
}

(async () => {
    const args = process.argv.slice(2);
    const ni = args.indexOf("--network");
    const isTestnet = ni === -1 || (args[ni + 1] || "testnet").toLowerCase() === "testnet";
    let hdPath = "44'/60'/0'/0/0";
    const pi = args.indexOf("--hd-path");
    if (pi !== -1 && args[pi + 1]) hdPath = args[pi + 1].replace(/^m\//, "").replace(/\\/g, "/");

    const api = isTestnet ? "https://api.hyperliquid-testnet.xyz/exchange" : "https://api.hyperliquid.xyz/exchange";
    const rpc = isTestnet ? "https://rpc.hyperliquid-testnet.xyz/evm" : "https://rpc.hyperliquid.xyz/evm";

    console.log("Connecting to Ledger. Unlock and open Ethereum app...");
    const transport = await TransportNodeHid.create();
    const eth = new Eth(transport);
    const { address } = await eth.getAddress(hdPath);
    const addr = address.toLowerCase();
    console.log("Ledger address:", addr);

    const action = { type: "evmUserModify", usingBigBlocks: true };
    const nonce = Date.now();

    // Use SDK low-level helper with our Ledger adapter
    const wallet = makeLedgerWalletAdapter({ eth, hdPath, address: addr });
    const signature = await signL1Action({ wallet, action, nonce, isTestnet });

    // Optional local sanity check: recover from the flat sig if bytes are exposed by your SDK version
    // If not available, you can skip local recovery.

    // POST to Exchange
    const payload = { action, nonce, signature };
    console.log("POST", api, JSON.stringify(payload));
    const { status, text } = await postJson(api, payload);
    console.log("Status:", status);
    console.log("Body:", text);

    await transport.close();

    // Verify the flag over RPC
    try {
        const provider = new ethers.JsonRpcProvider(rpc);
        const using = await provider.send("eth_usingBigBlocks", [addr]);
        console.log("eth_usingBigBlocks:", using);
    } catch (e) {
        console.log("RPC check skipped:", e.message);
    }
})().catch(async (e) => {
    console.error("Error:", e.message);
    console.error("Tips:");
    console.error("- Open the Ethereum app on Ledger and enable Blind signing.");
    console.error(
        "- If response says your own 0x... does not exist, initialize as a Core user by receiving any Core asset on testnet, then run again."
    );
    process.exit(1);
});
