const {
    ethers: {
        constants: { Zero, One, Two },
        utils: { keccak256, defaultAbiCoder, toUtf8Bytes, solidityPack },
        BigNumber
    }
} = hre;

rng = require("seedrandom")(); // Seed PRNG
const { IEEE754Buffer } = require("ieee754-buffer");

const PERMIT_TYPEHASH = keccak256(
    toUtf8Bytes("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
);

function getDomainSeparator(name, tokenAddress, chainId) {
    return keccak256(
        defaultAbiCoder.encode(
            ["bytes32", "bytes32", "bytes32", "uint256", "address"],
            [
                keccak256(
                    toUtf8Bytes("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
                ),
                keccak256(toUtf8Bytes(name)),
                keccak256(toUtf8Bytes("1")),
                chainId,
                tokenAddress
            ]
        )
    );
}

module.exports = new (function () {
    this.exponentOfBytes16 = (x) => {
        if (!/^0x/.exec(x)) throw "Not a hex string";

        const first16bits = Buffer.from(x.slice(2, 6), "hex").readUInt16BE();
        const exponent = first16bits & 0x7fff;

        if (exponent === 0 && x !== "0x00000000000000000000000000000000") throw "Subnormal number";
        const sgn = !!(first16bits & 0x8000);
        return { exponent, sgn };
    };

    this.bitLengthBigNumber = (x) => {
        if (x.isZero()) return 0;
        let xHex = x.toHexString();
        xHex = xHex.slice(xHex.charAt(2) === "0" ? 3 : 2);
        let len = xHex.length * 4;
        if (xHex.charAt(0) === "1") len -= 3;
        else if (new Set(["2", "3"]).has(xHex.charAt(0))) len -= 2;
        else if (new Set(["4", "5", "6", "7"]).has(xHex.charAt(0))) len--;
        return len;
    };

    this.deployTwoERC20 = async () => {
        // Deploy two mock tokens
        const MockERC20 = await ethers.getContractFactory("MockERC20");

        const [mockTkn0, mockTkn1] = await Promise.all([
            MockERC20.deploy("Mock Token 0", "TKN0", (Math.floor(rng() * 3) + 1) * 6),
            MockERC20.deploy("Mock Token 1", "TKN1", (Math.floor(rng() * 3) + 1) * 6)
        ]); // Random decimals

        // Order them by address magnitude
        const tokens =
            parseInt(mockTkn0.address.slice(2), 16) < parseInt(mockTkn1.address.slice(2), 16)
                ? [mockTkn0, mockTkn1]
                : [mockTkn1, mockTkn0];

        // Make equally probable that the smaller address is first or second
        if (rng() < 0.5) tokens.reverse();

        return tokens;
    };

    this.log10001 = (x) => {
        function log10001Element(y) {
            return Math.log(y) / Math.log(1.0001);
        }

        if (arguments.length === 0) throw "No arguments";
        else if (arguments.length === 1 && !Array.isArray(x)) return log10001Element(x);
        else return [...arguments].flat().map(log10001Element);
    };

    this.getApprovalDigest = async (token, approve, nonce, deadline) => {
        const name = await token.name();
        const DOMAIN_SEPARATOR = getDomainSeparator(
            name,
            token.address,
            Number(await hre.network.provider.send("eth_chainId", []))
        );
        return keccak256(
            solidityPack(
                ["bytes1", "bytes1", "bytes32", "bytes32"],
                [
                    "0x19",
                    "0x01",
                    DOMAIN_SEPARATOR,
                    keccak256(
                        defaultAbiCoder.encode(
                            ["bytes32", "address", "address", "uint256", "uint256", "uint256"],
                            [PERMIT_TYPEHASH, approve.owner, approve.spender, approve.value, nonce, deadline]
                        )
                    )
                ]
            )
        );
    };

    // This function loses precision during conversion
    this.bytes16ToNumber = (x) => {
        if (/^0x/.exec(x)) {
            const buf = Buffer.from(x.slice(2), "hex").reverse();
            return new IEEE754Buffer(15, 112).unpack(buf, 0);
        } else throw "Not a hex string";
    };

    this.numberToBytes16 = (x) => {
        // const buf = Buffer.alloc(16, "hex");
        // new IEEE754Buffer(15, 112).pack(buf, x, 0); // reverse?
        // return `0x${buf.reverse().toString("hex")}`;
        const buf = Buffer.alloc(9, "hex");
        new IEEE754Buffer(15, 52).pack(buf, x + 2 ** -50, 0);
        return `0x${buf.reverse().toString("hex")}00000000000000`;
    };

    this.randn = (len) => {
        let res = new Array(len);

        for (let i = 0; i < len; i++) {
            let u, v;
            do {
                u = rng();
            } while (u === 0); //Converting [0,1) to (0,1)
            do {
                v = rng();
            } while (v === 0);

            res[i] = Math.sqrt(-2.0 * Math.log(u)) * Math.cos(2.0 * Math.PI * v);
        }

        return res;
    };

    this.bytes16ToFraction = (x) => {
        if (!/^0x/.exec(x)) throw "Not a hex string";

        if (x === "0x00000000000000000000000000000000") return { num: Zero, den: One };
        if (x === "0x7fff0000000000000000000000000000") return { num: Infinity, den: One };

        const first16bits = Buffer.from(x.slice(2, 6), "hex").readUInt16BE();
        const exponent = first16bits & 0x7fff;
        if (exponent === 0) throw "Subnormal number";
        const sgn = !!(first16bits & 0x8000);

        let num = BigNumber.from(`0x1${x.slice(6)}`);
        if (sgn) num = num.mul(-1);
        let den = exponent <= 16383 + 112 ? Two.pow(112 + 16383 - exponent) : One;
        if (exponent > 16383 + 112) num = num.mul(Two.pow(exponent - 16383 - 112));

        // Reduce when possible
        while (num.mod(2).isZero() && den.mod(2).isZero()) {
            num = num.div(2);
            den = den.div(2);
        }

        return { num, den };
    };

    this.fractionToBytes16 = (num, den, roundUp) => {
        if (num === Infinity && den === Infinity) throw "NaN not a possible value";
        if (num === Infinity) return "0x7fff0000000000000000000000000000";

        num = BigNumber.from(num);
        den = BigNumber.from(den);
        if (num.isZero() && den.isZero()) throw "NaN not a possible value";
        if (num.isZero()) return "0x00000000000000000000000000000000";

        const isNeg = (num.lt(0) && den.gt(0)) || (num.gt(0) && den.lt(0));
        if (den.isZero()) return "0x7fff0000000000000000000000000000";

        // Sign
        num = num.abs();
        den = den.abs();

        // Signifier
        const lenNum = this.bitLengthBigNumber(num);

        const lenDen = this.bitLengthBigNumber(den);

        // Compute signifier with AT LEAST 113 bits
        let lenResMin1 = lenNum - lenDen - 1;
        let signifier;
        if (lenResMin1 < 112) {
            signifier = roundUp
                ? num
                      .mul(Two.pow(112 - lenResMin1))
                      .sub(1)
                      .div(den)
                      .add(1)
                : num.mul(Two.pow(112 - lenResMin1)).div(den);
        } else {
            signifier = roundUp
                ? num
                      .sub(1)
                      .div(den.mul(Two.pow(lenResMin1 - 112)))
                      .add(1)
                : num.div(den.mul(Two.pow(lenResMin1 - 112)));
        }

        // Correct lenResMin1 if necessary
        let signifierHex = signifier.toHexString();
        if (signifierHex.charAt(3) !== "1") {
            signifier = roundUp ? signifier.sub(1).div(2).add(1) : signifier.div(2);
            signifierHex = signifier.toHexString();
            lenResMin1++;

            if (signifierHex.charAt(3) !== "1") {
                // Possible if rounding up
                signifier = signifier.sub(1).div(2).add(1);
                signifierHex = signifier.toHexString();
                lenResMin1++;
            }
        }
        signifierHex = signifierHex.slice(4);

        // Exponent
        if (lenResMin1 > 16383) return "0x7fff0000000000000000000000000000";
        if (lenResMin1 < -16382) return "0x00000000000000000000000000000000";
        const exponentHex = (lenResMin1 + 16383 + (isNeg ? 2 ** 15 : 0)).toString(16);

        return `0x${exponentHex.padStart(4, "0")}${signifierHex}`;
    };

    this.randomUnsignedBytes16 = () => {
        let numb = [...Array(28)].map(() => Math.floor(rng() * 16).toString(16)).join("");
        const expo = (Math.floor(rng() * 32766) + 1) // 1 to 32766
            .toString(16)
            .padStart(4, "0");

        return `0x${expo}${numb}`;
    };

    this.randomUnsignedBytes16WithinUIntRange = () => {
        let numb = [...Array(28)].map(() => Math.floor(rng() * 16).toString(16)).join("");
        let expo = Math.floor(rng() * 256) + 16383; // 16383+0 to 16383+255
        expo = expo.toString(16).padStart(4, "0");

        return `0x${expo}${numb}`;
    };

    this.randomSignedBytes16 = () => {
        let numb = [...Array(28)].map(() => Math.floor(rng() * 16).toString(16)).join("");
        let expo = Math.floor(rng() * 32766) + 1; // 1 to 32766
        if (rng() < 0.5) expo += 2 ** 15;
        expo = expo.toString(16).padStart(4, "0");

        return `0x${expo}${numb}`;
    };

    this.randomSignedBytes16WithinUIntRange = () => {
        let numb = [...Array(28)].map(() => Math.floor(rng() * 16).toString(16)).join("");
        let expo = Math.floor(rng() * 256) + 16383; // 16383+0 to 16383+255
        if (rng() < 0.5) expo += 2 ** 15;
        expo = expo.toString(16).padStart(4, "0");

        return `0x${expo}${numb}`;
    };

    this.randomUnsignedBytes16WithinTickRange = () => {
        let numb = [...Array(28)].map(() => Math.floor(rng() * 16).toString(16)).join("");
        let expo = Math.floor(rng() * 257) + 16255; // 16383-128 to 16383+128
        expo = expo.toString(16).padStart(4, "0");

        return `0x${expo}${numb}`;
    };

    this.randomPrice = () => {
        // Unit-mean Rayleigh-distributed random variable
        const price = Math.sqrt((2 / Math.PI) * (this.randn(1)[0] ** 2 + this.randn(1)[0] ** 2));

        // priceNum / 2**112 is the actual price
        const priceNum = Two.pow(72).mul(Math.round(price * 2 ** 40)); // 40 bits actual precision

        // Convert to IEEE 754 quadruple precision
        let priceExponent = 16383;
        let priceSignifier = priceNum;
        while (priceSignifier.gte(Two.pow(113))) {
            priceSignifier = priceSignifier.div(Two);
            priceExponent++;
        }

        while (priceSignifier.lt(Two.pow(112))) {
            priceSignifier = priceSignifier.mul(Two);
            priceExponent--;
        }

        priceExponent = priceExponent.toString(16);
        return {
            priceNum,
            priceBytes16: `0x${"0".repeat(4 - priceExponent.length)}${priceExponent}${priceSignifier
                .toHexString()
                .slice(4)}`
        };
    };

    this.randomBigUint = () => {
        let bigUInt = BigNumber.from(`0x${[...Array(64)].map(() => Math.floor(rng() * 16).toString(16)).join("")}`);

        // Distribute uniformly by order of magnitude
        return bigUInt.mask(Math.floor(rng() * 256) + 1);
    };

    this.randomSignedBigUint = () => {
        let bigUInt = BigNumber.from(`0x${[...Array(64)].map(() => Math.floor(rng() * 16).toString(16)).join("")}`);

        // Distribute uniformly by order of magnitude and add random sign
        return bigUInt.mask(Math.floor(rng() * 255) + 1).mul(rng() < 0.5 ? 1 : -1);
    };

    this.mulBNxDecimal = ({ bigNumber, decimalNumber }) => {
        const safeNumber = Math.floor(Number.MAX_SAFE_INTEGER / 10);

        if (decimalNumber > 1) return bigNumber.mul(safeNumber).div(Math.round(safeNumber / decimalNumber));
        else if (decimalNumber < 1) return bigNumber.mul(Math.round(safeNumber * decimalNumber)).div(safeNumber);
        else return bigNumber;
    };

    this.divideBNsToDecimal = (a, b) => {
        return Number(a.toString()) / Number(b.toString());
    };

    this.addBytes16 = (x, y, roundUp) => {
        const fracX = this.bytes16ToFraction(x);
        const fracY = this.bytes16ToFraction(y);
        let num = fracX.num.mul(fracY.den).add(fracY.num.mul(fracX.den));
        const den = fracX.den.mul(fracY.den);
        const bytes16 = this.fractionToBytes16(num, den, roundUp);
        return { bytes16, num, den };
    };

    this.subBytes16 = (x, y, roundUp) => {
        const fracX = this.bytes16ToFraction(x);
        const fracY = this.bytes16ToFraction(y);
        let num = fracX.num.mul(fracY.den).sub(fracY.num.mul(fracX.den));
        const den = fracX.den.mul(fracY.den);
        const bytes16 = this.fractionToBytes16(num, den, roundUp);
        return { bytes16, num, den };
    };

    this.mulBytes16 = (x, y, roundUp) => {
        const fracX = this.bytes16ToFraction(x);
        const fracY = this.bytes16ToFraction(y);
        let num = fracX.num.mul(fracY.num);
        const den = fracX.den.mul(fracY.den);
        const bytes16 = this.fractionToBytes16(num, den, roundUp);
        return { bytes16, num, den };
    };

    this.divBytes16 = (x, y, roundUp) => {
        const fracX = this.bytes16ToFraction(x);
        const fracY = this.bytes16ToFraction(y);
        let num = fracX.num.mul(fracY.den);
        const den = fracX.den.mul(fracY.num);
        const bytes16 = this.fractionToBytes16(num, den, roundUp);
        return { bytes16, num, den };
    };
})();
