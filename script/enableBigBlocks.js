#!/usr/bin/env node

/**
 * Enable big blocks on Hyperliquid using a Ledger device or private key
 *
 * Usage:
 *   node script/enableBigBlocks.js [options]
 *
 * Options:
 *   --network <testnet|mainnet>  Network to use (default: testnet)
 *   --hd-path <path>             HD derivation path for Ledger (default: 44'/60'/0'/0/0)
 *   --private-key <key>          Private key (0x-prefixed hex). If provided, Ledger is not used.
 *   --rpc <url>                  Custom RPC URL (overrides network default)
 *
 * Examples:
 *   # Using Ledger (default)
 *   node script/enableBigBlocks.js
 *   node script/enableBigBlocks.js --network mainnet
 *   node script/enableBigBlocks.js --hd-path "44'/60'/0'/0/1"
 *
 *   # Using private key
 *   node script/enableBigBlocks.js --private-key 0xYourPrivateKeyHere
 *   node script/enableBigBlocks.js --private-key 0xYourPrivateKeyHere --rpc http://104.155.144.147:8545
 *   node script/enableBigBlocks.js --private-key 0xYourPrivateKeyHere --network mainnet
 */

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

// Build a private key wallet adapter that supports both personal_sign and EIP-712
function makePrivateKeyWalletAdapter(privateKey) {
    const wallet = new ethers.Wallet(privateKey);
    const addr = wallet.address.toLowerCase();

    return {
        address: addr,

        // Called for L1 actions that use EIP-191 (personal_sign) over canonical bytes
        async signMessage(messageBytes) {
            const message = ethers.hexlify(messageBytes);
            return await wallet.signMessage(ethers.getBytes(message));
        },

        // Some SDK paths request typed-data. Implement via ethers.
        // Input shape expected by the SDK:
        // { domain, types, message } (EIP-712 v4)
        async signTypedData({ domain, types, message }) {
            return await wallet.signTypedData(domain, types, message);
        }
    };
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

        // Some SDK paths request typed-data. Implement via Ledger's EIP-712.
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

    // Parse --network flag
    const ni = args.indexOf("--network");
    const isTestnet = ni === -1 || (args[ni + 1] || "testnet").toLowerCase() === "testnet";

    // Parse --hd-path flag
    let hdPath = "44'/60'/0'/0/0";
    const pi = args.indexOf("--hd-path");
    if (pi !== -1 && args[pi + 1]) hdPath = args[pi + 1].replace(/^m\//, "").replace(/\\/g, "/");

    // Parse --private-key flag
    const pki = args.indexOf("--private-key");
    const privateKey = pki !== -1 && args[pki + 1] ? args[pki + 1] : null;

    // Parse --rpc flag (overrides network default if provided)
    const ri = args.indexOf("--rpc");
    const api = isTestnet ? "https://api.hyperliquid-testnet.xyz/exchange" : "https://api.hyperliquid.xyz/exchange";
    const defaultRpc = isTestnet ? "https://rpc.hyperliquid-testnet.xyz/evm" : "https://rpc.hyperliquid.xyz/evm";
    const rpc = ri !== -1 && args[ri + 1] ? args[ri + 1] : defaultRpc;

    console.log("Network:", isTestnet ? "Testnet" : "Mainnet");
    console.log("API:", api);
    console.log("RPC:", rpc);

    let wallet, addr, transport;

    // Use private key or Ledger
    if (privateKey) {
        console.log("\nUsing private key...");
        wallet = makePrivateKeyWalletAdapter(privateKey);
        addr = wallet.address;
        console.log("Address:", addr);
    } else {
        console.log("\nConnecting to Ledger. Unlock and open Ethereum app...");
        transport = await TransportNodeHid.create();
        const eth = new Eth(transport);
        const { address } = await eth.getAddress(hdPath);
        addr = address.toLowerCase();
        console.log("Ledger address:", addr);
        wallet = makeLedgerWalletAdapter({ eth, hdPath, address: addr });
    }

    const action = { type: "evmUserModify", usingBigBlocks: true };
    const nonce = Date.now();

    // Use SDK low-level helper with our wallet adapter
    const signature = await signL1Action({ wallet, action, nonce, isTestnet });

    // POST to Exchange
    const payload = { action, nonce, signature };
    console.log("\nPOST", api, JSON.stringify(payload));
    const { status, text } = await postJson(api, payload);
    console.log("Status:", status);
    console.log("Body:", text);

    // Close Ledger transport if used
    if (transport) {
        await transport.close();
    }

    // Verify the flag over RPC
    try {
        const provider = new ethers.JsonRpcProvider(rpc);
        const using = await provider.send("eth_usingBigBlocks", [addr]);
        console.log("\neth_usingBigBlocks:", using);
    } catch (e) {
        console.log("\nRPC check skipped:", e.message);
    }
})().catch(async (e) => {
    console.error("Error:", e.message);
    console.error("\nTroubleshooting:");
    console.error("- If using Ledger: Open the Ethereum app on Ledger and enable Blind signing.");
    console.error("- If using private key: Ensure it starts with 0x and is 66 characters long.");
    console.error(
        "- If response says your address does not exist, initialize as a Core user by receiving any Core asset on testnet first."
    );
    process.exit(1);
});
