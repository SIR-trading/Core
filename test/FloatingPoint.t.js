const {
    BigNumber,
    constants: { Zero, One, Two, MaxUint256 }
} = ethers;

const { solidity } = require("ethereum-waffle");
const chai = require("chai");
chai.use(solidity);
const { expect } = chai;

const {
    bytes16ToFraction,
    fractionToBytes16,
    randomBigUint,
    randomSignedBigUint,
    randomUnsignedBytes16,
    randomSignedBytes16,
    randomSignedBytes16WithinUIntRange,
    randomUnsignedBytes16WithinUIntRange,
    bitLengthBigNumber,
    exponentOfBytes16,
    bytes16ToNumber,
    numberToBytes16,
    addBytes16,
    subBytes16,
    mulBytes16,
    divBytes16
} = require("./Utilities/utils.js");

const N = 100;
const rng = require("seedrandom")(); // Seedable RNG so we can repeat the experiment

const BN10 = BigNumber.from(100);

const ZERO_FP = "0x00000000000000000000000000000000";
const ONE_FP = "0x3fff0000000000000000000000000000";
const QUASI_ONE_FP = "0x3ffeffffffffffffffffffffffffffff";
const TAT_LG_ONE_FP = "0x3fff0000000000000000000000000001";
const INF_FP = "0x7fff0000000000000000000000000000";
const MAX_FP = "0x7ffeffffffffffffffffffffffffffff";
const MIN_FP = "0x00010000000000000000000000000000";

describe("Floating Point Library", function () {
    this.timeout(1000000);

    let floatingPoint;

    before(async function () {
        const FloatingPoint = await ethers.getContractFactory("$FloatingPoint");
        floatingPoint = await FloatingPoint.deploy();
    });

    it("ZERO", async function () {
        const bytes16A = ZERO_FP;

        expect(await floatingPoint.$ZERO()).to.be.equal(bytes16A);
    });

    it("ONE", async function () {
        const bytes16A = ONE_FP;

        expect(await floatingPoint.$ONE()).to.be.equal(bytes16A);
    });

    it("INFINITY", async function () {
        const bytes16A = INF_FP;

        expect(await floatingPoint.$INFINITY()).to.be.equal(bytes16A);
    });

    describe("fromInt", async function () {
        it("random signed integers", async function () {
            for (let i = 0; i < N; i++) {
                const intA = randomSignedBigUint();
                const bytes16B = fractionToBytes16(intA, 1);

                expect(await floatingPoint.$fromInt(intA)).to.be.equal(bytes16B);
            }
        });

        it("rounding error is bounded", async function () {
            for (let i = 0; i < N; i++) {
                const intA = randomSignedBigUint();
                const fracB = bytes16ToFraction(await floatingPoint.$fromInt(intA));

                if (bitLengthBigNumber(intA) <= 113) expect(intA.mul(fracB.den)).to.be.equal(fracB.num);
                else {
                    expect(fracB.num.abs().mul(Two.pow(112))).to.be.within(
                        fracB.den.abs().mul(intA.abs()).mul(Two.pow(112).sub(1)),
                        fracB.den.abs().mul(intA.abs()).mul(Two.pow(112))
                    );
                }
            }
        });

        it("largest int that UF", async function () {
            const intA = Two.pow(255).mul(-1).sub(1);

            try {
                await floatingPoint.$fromInt(intA);
            } catch (error) {
                expect(error.reason).to.be.equal("value out-of-bounds");
            }
        });

        it("smallest int", async function () {
            const intA = Two.pow(255).mul(-1);
            const bytes16B = fractionToBytes16(intA, 1);

            expect(await floatingPoint.$fromInt(intA)).to.be.equal(bytes16B);
        });

        it("0", async function () {
            const intA = Zero;
            const bytes16B = fractionToBytes16(intA, 1);

            expect(await floatingPoint.$fromInt(intA)).to.be.equal(bytes16B);
        });

        it("largest int", async function () {
            const intA = Two.pow(255).sub(1);
            const bytes16B = fractionToBytes16(intA, 1);

            expect(await floatingPoint.$fromInt(intA)).to.be.equal(bytes16B);
        });

        it("smallest int that OF", async function () {
            const intA = Two.pow(255);

            try {
                await floatingPoint.$fromInt(intA);
            } catch (error) {
                expect(error.reason).to.be.equal("value out-of-bounds");
            }
        });
    });

    describe("fromUInt", async function () {
        it("random signed integers", async function () {
            for (let i = 0; i < N; i++) {
                const uintA = randomBigUint();
                const bytes16B = fractionToBytes16(uintA, 1);

                expect(await floatingPoint.$fromUInt(uintA)).to.be.equal(bytes16B);
            }
        });

        it("rounding error is bounded", async function () {
            for (let i = 0; i < N; i++) {
                const uintA = randomBigUint();
                const fracB = bytes16ToFraction(await floatingPoint.$fromUInt(uintA));

                if (bitLengthBigNumber(uintA) <= 113) expect(uintA.mul(fracB.den)).to.be.equal(fracB.num);
                else {
                    expect(fracB.num.mul(Two.pow(112))).to.be.within(
                        fracB.den.mul(uintA).mul(Two.pow(112).sub(1)),
                        fracB.den.mul(uintA).mul(Two.pow(112))
                    );
                }
            }
        });

        it("largest uint that UF", async function () {
            const uintA = Zero.sub(1);

            try {
                await floatingPoint.$fromUInt(uintA);
            } catch (error) {
                expect(error.reason).to.be.equal("value out-of-bounds");
            }
        });

        it("0", async function () {
            const uintA = Zero;
            const bytes16B = fractionToBytes16(uintA, 1);

            expect(await floatingPoint.$fromUInt(uintA)).to.be.equal(bytes16B);
        });

        it("largest acceptable int", async function () {
            const uintA = Two.pow(256).sub(1);
            const bytes16B = fractionToBytes16(uintA, 1);

            expect(await floatingPoint.$fromUInt(uintA)).to.be.equal(bytes16B);
        });

        it("smallest int that OF", async function () {
            const uintA = Two.pow(256);

            try {
                await floatingPoint.$fromUInt(uintA);
            } catch (error) {
                expect(error.reason).to.be.equal("value out-of-bounds");
            }
        });
    });

    describe("fromUIntUp", async function () {
        it("random signed integers", async function () {
            for (let i = 0; i < N; i++) {
                const uintA = randomBigUint();
                const bytes16B = fractionToBytes16(uintA, 1, true);

                expect(await floatingPoint.$fromUIntUp(uintA)).to.be.equal(bytes16B);
            }
        });

        it("rounding error is bounded", async function () {
            for (let i = 0; i < N; i++) {
                const uintA = randomBigUint();
                const fracB = bytes16ToFraction(await floatingPoint.$fromUIntUp(uintA));

                if (bitLengthBigNumber(uintA) <= 113) expect(uintA.mul(fracB.den)).to.be.equal(fracB.num);
                else {
                    expect(fracB.num.mul(Two.pow(112))).to.be.within(
                        fracB.den.mul(uintA).mul(Two.pow(112)),
                        fracB.den.mul(uintA).mul(Two.pow(112).add(1))
                    );
                }
            }
        });

        it("largest uint that UF", async function () {
            const uintA = Zero.sub(1);

            try {
                await floatingPoint.$fromUIntUp(uintA);
            } catch (error) {
                expect(error.reason).to.be.equal("value out-of-bounds");
            }
        });

        it("0", async function () {
            const uintA = Zero;
            const bytes16B = fractionToBytes16(uintA, 1, true);

            expect(await floatingPoint.$fromUIntUp(uintA)).to.be.equal(bytes16B);
        });

        it("largest acceptable int", async function () {
            const uintA = Two.pow(256).sub(1);
            const bytes16B = fractionToBytes16(uintA, 1, true);

            expect(await floatingPoint.$fromUIntUp(uintA)).to.be.equal(bytes16B);
        });

        it("smallest int that OF", async function () {
            const uintA = Two.pow(256);

            try {
                await floatingPoint.$fromUIntUp(uintA);
            } catch (error) {
                expect(error.reason).to.be.equal("value out-of-bounds");
            }
        });

        // ADD TESTS THAT SHOW THE INCREASE IN LENGTH AND ALSO UP VS DOWN FUNCTION
        it("uint increases by 1 bit after rounding", async function () {
            for (let i = 0; i < N; i++) {
                let uintA = randomBigUint();

                // Leading 113 bits must be one and rest random
                const len = bitLengthBigNumber(uintA);
                if (len > 113) {
                    uintA = uintA.sub(uintA.div(Two.pow(len - 113)).mul(Two.pow(len - 113))).add(
                        Two.pow(113)
                            .sub(1)
                            .mul(Two.pow(len - 113))
                    );
                }

                const bytes16B = fractionToBytes16(uintA, 1, true);
                expect(await floatingPoint.$fromUIntUp(uintA)).to.be.equal(bytes16B);
            }
        });
    });

    describe("toUInt", async function () {
        it("random signed integers in the UInt range", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomSignedBytes16WithinUIntRange();
                const fracB = bytes16ToFraction(bytes16A);
                const uintB = fracB.num.div(fracB.den);

                if (fracB.num < 0) await expect(floatingPoint.$toUInt(bytes16A)).to.be.reverted;
                else expect(await floatingPoint.$toUInt(bytes16A)).to.be.equal(uintB);
            }
        });

        it("random signed integers", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomSignedBytes16();
                const fracB = bytes16ToFraction(bytes16A);
                const uintB = fracB.num.div(fracB.den);

                if (fracB.num < 0 || fracB.num.gt(fracB.den.mul(MaxUint256)))
                    await expect(floatingPoint.$toUInt(bytes16A)).to.be.reverted;
                else expect(await floatingPoint.$toUInt(bytes16A)).to.be.equal(uintB);
            }
        });

        it("rounding error is bounded", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomUnsignedBytes16WithinUIntRange();
                const fracA = bytes16ToFraction(bytes16A);
                const uintB = await floatingPoint.$toUInt(bytes16A);

                const exp = exponentOfBytes16(bytes16A).exponent - 16383;
                if (exp >= 112) expect(uintB.mul(fracA.den)).to.be.equal(fracA.num);
                else {
                    expect(uintB.mul(fracA.den).mul(Two.pow(exp))).to.be.within(
                        fracA.num.mul(Two.pow(exp).sub(1)),
                        fracA.num.mul(Two.pow(exp))
                    );
                }
            }
        });

        it("largest bytes16 that UF", async function () {
            const bytes16A = "0x80010000000000000000000000000000";

            await expect(floatingPoint.$toUInt(bytes16A)).to.be.reverted;
        });

        it("0", async function () {
            const bytes16A = ZERO_FP;

            expect(await floatingPoint.$toUInt(bytes16A)).to.be.equal(0);
        });

        it("largest bytes16 that rounds to 0", async function () {
            const bytes16A = "0x3FFEFFFFFFFFFFFFFFFFFFFFFFFFFFFF";

            expect(await floatingPoint.$toUInt(bytes16A)).to.be.equal(0);
        });

        it("smallest bytes16 that doesn't round to 0", async function () {
            const bytes16A = ONE_FP;

            expect(await floatingPoint.$toUInt(bytes16A)).to.be.equal(1);
        });

        it("largest bytes16 that rounds to MaxUint256", async function () {
            const bytes16A = "0x40FEFFFFFFFFFFFFFFFFFFFFFFFFFFFF";
            const uintB = MaxUint256.sub(MaxUint256.mask(256 - 113));

            expect(await floatingPoint.$toUInt(bytes16A)).to.be.equal(uintB);
        });

        it("smallest bytes16 that OF", async function () {
            const bytes16A = "0x40FF0000000000000000000000000000";

            await expect(floatingPoint.$toUInt(bytes16A)).to.be.reverted;
        });

        it("infinity", async function () {
            const bytes16A = INF_FP;

            await expect(floatingPoint.$toUInt(bytes16A)).to.be.reverted;
        });
    });

    describe("sign", async function () {
        it("random floating point numbers", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomSignedBytes16();
                let { num } = bytes16ToFraction(bytes16A);
                const sgnB = num.isZero() ? num : num.div(num.abs());

                expect(await floatingPoint.$sign(bytes16A)).to.be.equal(sgnB);
            }
        });

        it("- inf", async function () {
            const bytes16A = "0xffff0000000000000000000000000000";

            expect(await floatingPoint.$sign(bytes16A)).to.be.equal(-1);
        });

        it("- max", async function () {
            const bytes16A = "0xBffeffffffffffffffffffffffffffff";

            expect(await floatingPoint.$sign(bytes16A)).to.be.equal(-1);
        });

        it("-1", async function () {
            const bytes16A = "0xBfff0000000000000000000000000000";

            expect(await floatingPoint.$sign(bytes16A)).to.be.equal(-1);
        });

        it("0", async function () {
            const bytes16A = ZERO_FP;

            expect(await floatingPoint.$sign(bytes16A)).to.be.equal(0);
        });

        it("1", async function () {
            const bytes16A = ONE_FP;

            expect(await floatingPoint.$sign(bytes16A)).to.be.equal(1);
        });

        it("max", async function () {
            const bytes16A = MAX_FP;

            expect(await floatingPoint.$sign(bytes16A)).to.be.equal(1);
        });

        it("inf", async function () {
            const bytes16A = INF_FP;

            expect(await floatingPoint.$sign(bytes16A)).to.be.equal(1);
        });
    });

    describe("cmp", async function () {
        it("random pairs of floating point numbers", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomSignedBytes16();
                const bytes16B = randomSignedBytes16();

                const { num } = subBytes16(bytes16A, bytes16B);
                const sgnC = num.isZero() ? 0 : num.div(num.abs());

                expect(await floatingPoint.$cmp(bytes16A, bytes16B)).to.be.equal(sgnC);
            }
        });

        it("random pairs of equal floating point numbers", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomSignedBytes16();

                expect(await floatingPoint.$cmp(bytes16A, bytes16A)).to.be.equal(0);
            }
        });

        it("number vs. inf", async function () {
            const bytes16A = randomSignedBytes16();
            const bytes16B = INF_FP;

            expect(await floatingPoint.$cmp(bytes16A, bytes16B)).to.be.equal(-1);
        });

        it("inf vs. number", async function () {
            const bytes16A = INF_FP;
            const bytes16B = randomSignedBytes16();

            expect(await floatingPoint.$cmp(bytes16A, bytes16B)).to.be.equal(1);
        });

        it("inf vs. inf", async function () {
            const bytes16A = INF_FP;
            const bytes16B = INF_FP;

            await expect(floatingPoint.$cmp(bytes16A, bytes16B)).to.reverted;
        });
    });

    describe("add", async function () {
        it("random pairs of floating point numbers", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomSignedBytes16();
                const bytes16B = randomSignedBytes16();
                const bytes16C = addBytes16(bytes16A, bytes16B).bytes16;

                const fracA = bytes16ToFraction(bytes16A);
                const fracB = bytes16ToFraction(bytes16B);

                if (fracA.num.lt(0) || fracB.num.lt(0) || bytes16C === INF_FP)
                    await expect(floatingPoint.$add(bytes16A, bytes16B)).to.be.reverted;
                else expect(await floatingPoint.$add(bytes16A, bytes16B)).to.be.equal(bytes16C);
            }
        });

        it("rounding error is bounded", async function () {
            for (let i = 0; i < N; i++) {
                let bytes16A;
                let bytes16B;
                while (
                    addBytes16((bytes16A = randomUnsignedBytes16()), (bytes16B = randomUnsignedBytes16())).num ===
                    Infinity
                );
                const { num, den } = addBytes16(bytes16A, bytes16B); // No rounding

                const fracC = bytes16ToFraction(await floatingPoint.$add(bytes16A, bytes16B));

                expect(fracC.num.mul(den).mul(Two.pow(112))).to.be.within(
                    fracC.den.mul(num).mul(Two.pow(112).sub(1)),
                    fracC.den.mul(num).mul(Two.pow(112))
                );
            }
        });

        it("1⁻ + 1⁻", async function () {
            const bytes16A = QUASI_ONE_FP;
            const bytes16B = QUASI_ONE_FP;
            const bytes16C = addBytes16(QUASI_ONE_FP, QUASI_ONE_FP, false).bytes16;

            expect(await floatingPoint.$add(bytes16A, bytes16B)).to.be.equal(bytes16C);
        });

        it("max + largest that does not OF", async function () {
            const bytes16A = MAX_FP;
            const bytes16B = "0x7F8DFFFFFFFFFFFFFFFFFFFFFFFFFFFF";

            await expect(floatingPoint.$add(bytes16A, bytes16B)).to.not.be.reverted;
        });

        it("max + smallest that OFs", async function () {
            const bytes16A = MAX_FP;
            const bytes16B = "0x7F8E0000000000000000000000000000";

            await expect(floatingPoint.$add(bytes16A, bytes16B)).to.be.reverted;
        });

        it("number + inf", async function () {
            const bytes16A = randomUnsignedBytes16();
            const bytes16B = INF_FP;

            await expect(floatingPoint.$add(bytes16A, bytes16B)).to.be.reverted;
        });

        it("inf + number", async function () {
            const bytes16A = INF_FP;
            const bytes16B = randomUnsignedBytes16();

            await expect(floatingPoint.$add(bytes16A, bytes16B)).to.be.reverted;
        });

        it("inf + inf", async function () {
            const bytes16A = INF_FP;
            const bytes16B = INF_FP;

            await expect(floatingPoint.$add(bytes16A, bytes16B)).to.be.reverted;
        });

        it("random pairs that almost overflow", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomUnsignedBytes16();
                const bytes16B = subBytes16(MAX_FP, bytes16A, true).bytes16;
                const bytes16C = MAX_FP;

                expect(await floatingPoint.$add(bytes16A, bytes16B)).to.be.equal(bytes16C);
            }
        });
    });

    describe("addUp", async function () {
        it("random pairs of floating point numbers", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomSignedBytes16();
                const bytes16B = randomSignedBytes16();

                const fracA = bytes16ToFraction(bytes16A);
                const fracB = bytes16ToFraction(bytes16B);

                const bytes16C = addBytes16(bytes16A, bytes16B, true).bytes16;

                if (fracA.num.lt(0) || fracB.num.lt(0) || bytes16C === INF_FP)
                    await expect(floatingPoint.$addUp(bytes16A, bytes16B)).to.be.reverted;
                else expect(await floatingPoint.$addUp(bytes16A, bytes16B)).to.be.equal(bytes16C);
            }
        });

        it("rounding error is bounded", async function () {
            for (let i = 0; i < N; i++) {
                let bytes16A;
                let bytes16B;
                while (
                    addBytes16((bytes16A = randomUnsignedBytes16()), (bytes16B = randomUnsignedBytes16()), true).num ===
                    Infinity
                );
                const { num, den, bytes16 } = addBytes16(bytes16A, bytes16B); // No rounding

                if (bytes16 !== INF_FP) {
                    const fracC = bytes16ToFraction(await floatingPoint.$addUp(bytes16A, bytes16B));

                    expect(fracC.num.mul(den).mul(Two.pow(112))).to.be.within(
                        fracC.den.mul(num).mul(Two.pow(112)),
                        fracC.den.mul(num).mul(Two.pow(112).add(1))
                    );
                }
            }
        });

        it("1⁻ + 1⁻", async function () {
            const bytes16A = QUASI_ONE_FP;
            const bytes16B = QUASI_ONE_FP;
            const bytes16C = addBytes16(bytes16A, bytes16B, true).bytes16;

            expect(await floatingPoint.$addUp(bytes16A, bytes16B)).to.be.equal(bytes16C);
        });

        it("max + largest that does not OF", async function () {
            const bytes16A = MAX_FP;
            const bytes16B = ZERO_FP;

            await expect(floatingPoint.$addUp(bytes16A, bytes16B)).to.not.be.reverted;
        });

        it("max + smallest that OFs", async function () {
            const bytes16A = MAX_FP;
            const bytes16B = MIN_FP;

            await expect(floatingPoint.$addUp(bytes16A, bytes16B)).to.be.reverted;
        });

        it("number + inf", async function () {
            const bytes16A = randomUnsignedBytes16();
            const bytes16B = INF_FP;

            await expect(floatingPoint.$addUp(bytes16A, bytes16B)).to.be.reverted;
        });

        it("inf + number", async function () {
            const bytes16A = INF_FP;
            const bytes16B = randomUnsignedBytes16();

            await expect(floatingPoint.$addUp(bytes16A, bytes16B)).to.be.reverted;
        });

        it("inf + inf", async function () {
            const bytes16A = INF_FP;
            const bytes16B = INF_FP;

            await expect(floatingPoint.$addUp(bytes16A, bytes16B)).to.be.reverted;
        });

        it("random pairs that barely overflow", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomUnsignedBytes16();
                const bytes16B = subBytes16(MAX_FP, bytes16A, true).bytes16;
                const bytes16C = MAX_FP;

                if (subBytes16(MAX_FP, bytes16A, false) === bytes16B)
                    await expect(floatingPoint.$addUp(bytes16A, bytes16B)).to.be.equal(bytes16C);
                else await expect(floatingPoint.$addUp(bytes16A, bytes16B)).to.be.reverted;
            }
        });
    });

    describe("inc", async function () {
        it("random floating point numbers", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomSignedBytes16();
                const fracA = bytes16ToFraction(bytes16A);
                const bytes16B = fractionToBytes16(fracA.num.add(fracA.den), fracA.den);

                if (fracA.num.lt(0)) await expect(floatingPoint.$inc(bytes16A)).to.be.reverted;
                else expect(await floatingPoint.$inc(bytes16A)).to.be.equal(bytes16B);
            }
        });

        it("rounding error is bounded", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomUnsignedBytes16();
                const bytes16B = await floatingPoint.$inc(bytes16A);
                const fracB = bytes16ToFraction(bytes16B);
                const { num, den } = addBytes16(bytes16A, ONE_FP); // No rounding

                const exp = exponentOfBytes16(bytes16B).exponent;
                if (exp >= 0x4070) expect(bytes16B).to.be.equal(bytes16B);
                else if (exp >= 0x3fff)
                    expect(fracB.num.mul(den).mul(Two.pow(112))).to.be.within(
                        fracB.den.mul(num).mul(Two.pow(112).sub(1)),
                        fracB.den.mul(num).mul(Two.pow(112))
                    );
                else if (exp >= 0x3f8f)
                    expect(fracB.num.mul(den).mul(Two.pow(0x3fff - exp))).to.be.within(
                        fracB.den.mul(num).mul(Two.pow(0x3fff - exp).sub(1)),
                        fracB.den.mul(num).mul(Two.pow(0x3fff - exp))
                    );
                else expect(bytes16B).to.be.equal(ONE_FP);
            }
        });

        it("largest number that is 1 regardless", async function () {
            const bytes16A = "0x3f8effffffffffffffffffffffffffff";

            expect(await floatingPoint.$inc(bytes16A)).to.be.equal(ONE_FP);
        });

        it("smallest number that is incremented", async function () {
            const bytes16A = "0x3f8f0000000000000000000000000000";

            expect(await floatingPoint.$inc(bytes16A)).to.not.be.equal(ONE_FP);
            expect(await floatingPoint.$inc(bytes16A)).to.not.be.equal(bytes16A);
        });

        it("largest number that is incremented", async function () {
            const bytes16A = "0x406fffffffffffffffffffffffffffff";

            expect(await floatingPoint.$inc(bytes16A)).to.not.be.equal(ONE_FP);
            expect(await floatingPoint.$inc(bytes16A)).to.not.be.equal(bytes16A);
        });

        it("smallest number that is not incremented", async function () {
            const bytes16A = "0x40700000000000000000000000000000";

            expect(await floatingPoint.$inc(bytes16A)).to.be.equal(bytes16A);
        });

        it("almost overflows", async function () {
            const bytes16A = subBytes16(MAX_FP, ONE_FP, true).bytes16;
            const bytes16B = MAX_FP;

            expect(await floatingPoint.$inc(bytes16A)).to.be.equal(bytes16B);
        });

        it("inf", async function () {
            const bytes16A = INF_FP;

            await expect(floatingPoint.$inc(bytes16A)).to.be.reverted;
        });
    });

    describe("sub", async function () {
        it("random pairs of floating point numbers", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomSignedBytes16();
                const bytes16B = randomSignedBytes16();

                const fracA = bytes16ToFraction(bytes16A);
                const fracB = bytes16ToFraction(bytes16B);
                const num = fracA.num.mul(fracB.den).sub(fracB.num.mul(fracA.den));
                const den = fracA.den.mul(fracB.den);

                if (fracA.num.mul(fracB.den).lt(fracB.num.mul(fracA.den)) || fracB.num.lt(0))
                    await expect(floatingPoint.$sub(bytes16A, bytes16B)).to.be.reverted;
                else expect(await floatingPoint.$sub(bytes16A, bytes16B)).to.be.equal(fractionToBytes16(num, den));
            }
        });

        it("rounding error is bounded", async function () {
            for (let i = 0; i < N; i++) {
                let bytes16A;
                let bytes16B;
                while (
                    subBytes16((bytes16A = randomUnsignedBytes16()), (bytes16B = randomUnsignedBytes16())).num.lt(0)
                );
                const { num, den } = subBytes16(bytes16A, bytes16B); // No rounding

                const fracC = bytes16ToFraction(await floatingPoint.$sub(bytes16A, bytes16B));

                expect(fracC.num.mul(den).mul(Two.pow(112))).to.be.within(
                    fracC.den.mul(num).mul(Two.pow(112).sub(1)),
                    fracC.den.mul(num).mul(Two.pow(112))
                );
            }
        });

        it("0 - min", async function () {
            const bytes16A = ZERO_FP;
            const bytes16B = MIN_FP;

            await expect(floatingPoint.$sub(bytes16A, bytes16B)).to.be.reverted;
        });

        it("max - max", async function () {
            const bytes16A = MAX_FP;
            const bytes16B = MAX_FP;
            const bytes16C = ZERO_FP;

            expect(await floatingPoint.$sub(bytes16A, bytes16B)).to.be.equal(bytes16C);
        });

        it("number - inf", async function () {
            const bytes16A = randomUnsignedBytes16();
            const bytes16B = INF_FP;

            await expect(floatingPoint.$sub(bytes16A, bytes16B)).to.be.reverted;
        });

        it("inf - number", async function () {
            const bytes16A = INF_FP;
            const bytes16B = randomUnsignedBytes16();

            await expect(floatingPoint.$sub(bytes16A, bytes16B)).to.be.reverted;
        });

        it("inf - inf", async function () {
            const bytes16A = INF_FP;
            const bytes16B = INF_FP;

            await expect(floatingPoint.$sub(bytes16A, bytes16B)).to.be.reverted;
        });

        it("random pairs that almost underflow", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomUnsignedBytes16();
                const { num, den } = bytes16ToFraction(bytes16A);
                const bytes16B = fractionToBytes16(num.mul(Two.pow(113).add(One)), den.mul(Two.pow(113)));
                const bytes16C = ZERO_FP;

                expect(await floatingPoint.$sub(bytes16A, bytes16B)).to.be.equal(bytes16C);
            }
        });

        it("random pairs that barely underflow", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomUnsignedBytes16();
                const bytes16B = addBytes16(bytes16A, MIN_FP, true).bytes16;

                await expect(floatingPoint.$sub(bytes16A, bytes16B)).to.be.reverted;
            }
        });
    });

    describe("subUp", async function () {
        it("random pairs of floating point numbers", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomSignedBytes16();
                const bytes16B = randomSignedBytes16();

                const fracA = bytes16ToFraction(bytes16A);
                const fracB = bytes16ToFraction(bytes16B);
                const bytes16C = subBytes16(bytes16A, bytes16B, true).bytes16;

                if (fracA.num.mul(fracB.den).lt(fracB.num.mul(fracA.den)) || fracB.num.lt(0))
                    await expect(floatingPoint.$subUp(bytes16A, bytes16B)).to.be.reverted;
                else expect(await floatingPoint.$subUp(bytes16A, bytes16B)).to.be.equal(bytes16C);
            }
        });

        it("rounding error is bounded", async function () {
            for (let i = 0; i < N; i++) {
                let bytes16A;
                let bytes16B;
                while (
                    subBytes16((bytes16A = randomUnsignedBytes16()), (bytes16B = randomUnsignedBytes16()), true).num.lt(
                        0
                    )
                );
                const { num, den } = subBytes16(bytes16A, bytes16B); // No rounding

                const fracC = bytes16ToFraction(await floatingPoint.$subUp(bytes16A, bytes16B));

                expect(fracC.num.mul(den).mul(Two.pow(112))).to.be.within(
                    fracC.den.mul(num).mul(Two.pow(112)),
                    fracC.den.mul(num).mul(Two.pow(112).add(1))
                );
            }
        });

        it("0 - min", async function () {
            const bytes16A = ZERO_FP;
            const bytes16B = MIN_FP;

            await expect(floatingPoint.$subUp(bytes16A, bytes16B)).to.be.reverted;
        });

        it("number - inf", async function () {
            const bytes16A = randomUnsignedBytes16();
            const bytes16B = INF_FP;

            await expect(floatingPoint.$subUp(bytes16A, bytes16B)).to.be.reverted;
        });

        it("inf - number", async function () {
            const bytes16A = INF_FP;
            const bytes16B = randomUnsignedBytes16();

            await expect(floatingPoint.$subUp(bytes16A, bytes16B)).to.be.reverted;
        });

        it("inf - inf", async function () {
            const bytes16A = INF_FP;
            const bytes16B = INF_FP;

            await expect(floatingPoint.$subUp(bytes16A, bytes16B)).to.be.reverted;
        });

        it("max - max", async function () {
            const bytes16A = MAX_FP;
            const bytes16B = MAX_FP;
            const bytes16C = ZERO_FP;

            expect(await floatingPoint.$subUp(bytes16A, bytes16B)).to.be.equal(bytes16C);
        });

        it("random pairs that almost underflow", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomUnsignedBytes16();
                const { num, den } = bytes16ToFraction(bytes16A);
                const bytes16B = fractionToBytes16(num.mul(Two.pow(113).add(One)), den.mul(Two.pow(113)));
                const bytes16C = ZERO_FP;

                expect(await floatingPoint.$subUp(bytes16A, bytes16B)).to.be.equal(ZERO_FP);
            }
        });

        it("random pairs that barely underflow", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomUnsignedBytes16();
                const bytes16B = addBytes16(bytes16A, MIN_FP, true).bytes16;

                await expect(floatingPoint.$sub(bytes16A, bytes16B)).to.be.reverted;
            }
        });
    });

    describe("mul", async function () {
        it("random pairs of floating point numbers", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomSignedBytes16();
                const bytes16B = randomSignedBytes16();
                const fracB = bytes16ToFraction(bytes16B);
                const bytes16C = mulBytes16(bytes16A, bytes16B).bytes16;

                if (fracB.num.lt(0) || bytes16C === INF_FP)
                    await expect(floatingPoint.$mul(bytes16A, bytes16B)).to.be.reverted;
                else expect(await floatingPoint.$mul(bytes16A, bytes16B)).to.be.equal(bytes16C);
            }
        });

        it("rounding error is bounded", async function () {
            for (let i = 0; i < N; i++) {
                let bytes16A, bytes16B;
                let num, den, bytes16;
                do {
                    ({ num, den, bytes16 } = mulBytes16(
                        (bytes16A = randomUnsignedBytes16()),
                        (bytes16B = randomUnsignedBytes16())
                    ));
                } while (bytes16 === INF_FP || bytes16 === ZERO_FP);

                const fracC = bytes16ToFraction(await floatingPoint.$mul(bytes16A, bytes16B));

                expect(fracC.num.mul(den).mul(Two.pow(112))).to.be.within(
                    fracC.den.mul(num).mul(Two.pow(112).sub(1)),
                    fracC.den.mul(num).mul(Two.pow(112))
                );
            }
        });

        it("1⁻ * 1⁻", async function () {
            const bytes16A = QUASI_ONE_FP;
            const bytes16B = QUASI_ONE_FP;
            const bytes16C = mulBytes16(QUASI_ONE_FP, QUASI_ONE_FP, false).bytes16;

            expect(await floatingPoint.$mul(bytes16A, bytes16B)).to.be.equal(bytes16C);
        });

        it("min * 1", async function () {
            const bytes16A = MIN_FP;
            const bytes16B = ONE_FP;
            const bytes16C = MIN_FP;

            expect(await floatingPoint.$mul(bytes16A, bytes16B)).to.be.equal(bytes16C);
        });

        it("min * 1⁻", async function () {
            const bytes16A = MIN_FP;
            const bytes16B = "0x3ffeffffffffffffffffffffffffffff";
            const bytes16C = ZERO_FP;

            expect(await floatingPoint.$mul(bytes16A, bytes16B)).to.be.equal(bytes16C);
        });

        it("max * 1", async function () {
            const bytes16A = MAX_FP;
            const bytes16B = ONE_FP;
            const bytes16C = MAX_FP;

            expect(await floatingPoint.$mul(bytes16A, bytes16B)).to.be.equal(bytes16C);
        });

        it("max * 1⁺", async function () {
            const bytes16A = MAX_FP;
            const bytes16B = TAT_LG_ONE_FP;

            await expect(floatingPoint.$mul(bytes16A, bytes16B)).to.be.reverted;
        });

        it("number * inf", async function () {
            const bytes16A = randomSignedBytes16();
            const bytes16B = INF_FP;

            await expect(floatingPoint.$mul(bytes16A, bytes16B)).to.be.reverted;
        });

        it("inf * number", async function () {
            const bytes16A = INF_FP;
            const bytes16B = randomUnsignedBytes16();

            await expect(floatingPoint.$mul(bytes16A, bytes16B)).to.be.reverted;
        });

        it("inf * inf", async function () {
            const bytes16A = INF_FP;
            const bytes16B = INF_FP;

            await expect(floatingPoint.$mul(bytes16A, bytes16B)).to.be.reverted;
        });

        it("random pairs that barely overflow", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomUnsignedBytes16();
                let bytes16B = divBytes16(MAX_FP, bytes16A, true).bytes16;
                let bytes16C = bytes16B === INF_FP ? INF_FP : mulBytes16(bytes16A, bytes16B).bytes16;

                if (bytes16C === INF_FP) await expect(floatingPoint.$mul(bytes16A, bytes16B)).to.be.reverted;
                else expect(await floatingPoint.$mul(bytes16A, bytes16B)).to.be.equal(bytes16C);

                bytes16B = divBytes16(MAX_FP, bytes16A, false).bytes16;
                bytes16C = bytes16B === INF_FP ? INF_FP : mulBytes16(bytes16A, bytes16B).bytes16;

                if (bytes16C === INF_FP) await expect(floatingPoint.$mul(bytes16A, bytes16B)).to.be.reverted;
                else expect(await floatingPoint.$mul(bytes16A, bytes16B)).to.be.equal(bytes16C);
            }
        });
    });

    describe("mulUp", async function () {
        it("random pairs of floating point numbers", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomSignedBytes16();
                const bytes16B = randomSignedBytes16();
                const fracA = bytes16ToFraction(bytes16A);
                const fracB = bytes16ToFraction(bytes16B);
                const bytes16C = mulBytes16(bytes16A, bytes16B, true).bytes16;

                if (fracA.num.lt(0) || fracB.num.lt(0) || bytes16C === INF_FP)
                    await expect(floatingPoint.$mulUp(bytes16A, bytes16B)).to.be.reverted;
                else expect(await floatingPoint.$mulUp(bytes16A, bytes16B)).to.be.equal(bytes16C);
            }
        });

        it("rounding error is bounded", async function () {
            for (let i = 0; i < N; i++) {
                let bytes16A, bytes16B;
                let num, den, bytes16;
                do {
                    ({ num, den, bytes16 } = mulBytes16(
                        (bytes16A = randomUnsignedBytes16()),
                        (bytes16B = randomUnsignedBytes16()),
                        true
                    ));
                } while (bytes16 === INF_FP || bytes16 === ZERO_FP);

                const fracC = bytes16ToFraction(await floatingPoint.$mulUp(bytes16A, bytes16B));

                expect(fracC.num.mul(den).mul(Two.pow(112))).to.be.within(
                    fracC.den.mul(num).mul(Two.pow(112)),
                    fracC.den.mul(num).mul(Two.pow(112).add(1))
                );
            }
        });

        it("1⁻ * 1⁻", async function () {
            const bytes16A = QUASI_ONE_FP;
            const bytes16B = QUASI_ONE_FP;
            const bytes16C = mulBytes16(bytes16A, bytes16B, true).bytes16;

            expect(await floatingPoint.$mulUp(bytes16A, bytes16B)).to.be.equal(bytes16C);
        });

        it("min * 1⁻ ", async function () {
            const bytes16A = MIN_FP;
            const bytes16B = "0x3ffeffffffffffffffffffffffffffff";
            const bytes16C = ZERO_FP;

            expect(await floatingPoint.$mulUp(bytes16A, bytes16B)).to.be.equal(bytes16C);
        });

        it("min * 1", async function () {
            const bytes16A = MIN_FP;
            const bytes16B = ONE_FP;
            const bytes16C = MIN_FP;

            expect(await floatingPoint.$mulUp(bytes16A, bytes16B)).to.be.equal(bytes16C);
        });

        it("1⁻ * 1⁻", async function () {
            const bytes16A = QUASI_ONE_FP;
            const bytes16B = QUASI_ONE_FP;
            const bytes16C = mulBytes16(bytes16A, bytes16B, true).bytes16;

            expect(await floatingPoint.$mulUp(bytes16A, bytes16B)).to.be.equal(bytes16C);
        });

        it("max * 1", async function () {
            const bytes16A = MAX_FP;
            const bytes16B = ONE_FP;
            const bytes16C = MAX_FP;

            expect(await floatingPoint.$mulUp(bytes16A, bytes16B)).to.be.equal(bytes16C);
        });

        it("max * 1⁺", async function () {
            const bytes16A = MAX_FP;
            const bytes16B = TAT_LG_ONE_FP;

            await expect(floatingPoint.$mulUp(bytes16A, bytes16B)).to.be.reverted;
        });

        it("number * inf", async function () {
            const bytes16A = randomUnsignedBytes16();
            const bytes16B = INF_FP;

            await expect(floatingPoint.$mulUp(bytes16A, bytes16B)).to.be.reverted;
        });

        it("inf * number", async function () {
            const bytes16A = INF_FP;
            const bytes16B = randomUnsignedBytes16();

            await expect(floatingPoint.$mulUp(bytes16A, bytes16B)).to.be.reverted;
        });

        it("inf * inf", async function () {
            const bytes16A = INF_FP;
            const bytes16B = INF_FP;

            await expect(floatingPoint.$mulUp(bytes16A, bytes16B)).to.be.reverted;
        });

        it("random pairs that barely overflow", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomUnsignedBytes16();
                let bytes16B = divBytes16(MAX_FP, bytes16A, true).bytes16;
                let bytes16C = bytes16B === INF_FP ? INF_FP : mulBytes16(bytes16A, bytes16B, true).bytes16;

                if (bytes16C === INF_FP) await expect(floatingPoint.$mulUp(bytes16A, bytes16B)).to.be.reverted;
                else expect(await floatingPoint.$mulUp(bytes16A, bytes16B)).to.be.equal(bytes16C);

                bytes16B = divBytes16(MAX_FP, bytes16A, false).bytes16;
                bytes16C = bytes16B === INF_FP ? INF_FP : mulBytes16(bytes16A, bytes16B, true).bytes16;

                if (bytes16C === INF_FP) await expect(floatingPoint.$mulUp(bytes16A, bytes16B)).to.be.reverted;
                else expect(await floatingPoint.$mulUp(bytes16A, bytes16B)).to.be.equal(bytes16C);
            }
        });
    });

    describe("div", async function () {
        it("random pairs of floating point numbers", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomSignedBytes16();
                const bytes16B = randomSignedBytes16();
                const bytes16C = divBytes16(bytes16A, bytes16B).bytes16;

                const fracA = bytes16ToFraction(bytes16A);
                const fracB = bytes16ToFraction(bytes16B);

                if (fracA.num.lt(0) || fracB.num.lte(0))
                    await expect(floatingPoint.$div(bytes16A, bytes16B)).to.be.reverted;
                else expect(await floatingPoint.$div(bytes16A, bytes16B)).to.be.equal(bytes16C);
            }
        });

        it("rounding error is bounded", async function () {
            for (let i = 0; i < N; i++) {
                let bytes16A, bytes16B;
                let num, den, bytes16;
                do {
                    ({ num, den, bytes16 } = divBytes16(
                        (bytes16A = randomUnsignedBytes16()),
                        (bytes16B = randomUnsignedBytes16())
                    ));
                } while (bytes16 === INF_FP || bytes16 === ZERO_FP);

                const fracC = bytes16ToFraction(await floatingPoint.$div(bytes16A, bytes16B));

                expect(fracC.num.mul(den).mul(Two.pow(112))).to.be.within(
                    fracC.den.mul(num).mul(Two.pow(112).sub(1)),
                    fracC.den.mul(num).mul(Two.pow(112))
                );
            }
        });

        it("0 / number", async function () {
            const bytes16A = ZERO_FP;
            const bytes16B = randomUnsignedBytes16();
            const bytes16C = ZERO_FP;

            expect(await floatingPoint.$div(bytes16A, bytes16B)).to.be.equal(bytes16C);
        });

        it("number / 0", async function () {
            const bytes16A = randomUnsignedBytes16();
            const bytes16B = ZERO_FP;

            await expect(floatingPoint.$div(bytes16A, bytes16B)).to.be.reverted;
        });

        it("number / inf", async function () {
            const bytes16A = randomUnsignedBytes16();
            const bytes16B = INF_FP;

            await expect(floatingPoint.$div(bytes16A, bytes16B)).to.be.reverted;
        });

        it("inf / number", async function () {
            const bytes16A = INF_FP;
            const bytes16B = randomUnsignedBytes16();

            await expect(floatingPoint.$div(bytes16A, bytes16B)).to.be.reverted;
        });

        it("inf / inf", async function () {
            const bytes16A = INF_FP;
            const bytes16B = INF_FP;

            await expect(floatingPoint.$div(bytes16A, bytes16B)).to.be.reverted;
        });

        it("0 / inf", async function () {
            const bytes16A = ZERO_FP;
            const bytes16B = INF_FP;

            await expect(floatingPoint.$div(bytes16A, bytes16B)).to.be.reverted;
        });

        it("min / 1", async function () {
            const bytes16A = MIN_FP;
            const bytes16B = ONE_FP;
            const bytes16C = MIN_FP;

            expect(await floatingPoint.$div(bytes16A, bytes16B)).to.be.equal(bytes16C);
        });

        it("min / 1⁺ that results in 0", async function () {
            const bytes16A = MIN_FP;
            const bytes16B = TAT_LG_ONE_FP;
            const bytes16C = ZERO_FP;

            expect(await floatingPoint.$div(bytes16A, bytes16B)).to.be.equal(bytes16C);
        });

        it("max / 1 that does not OF", async function () {
            const bytes16A = MAX_FP;
            const bytes16B = ONE_FP;
            const bytes16C = MAX_FP;

            expect(await floatingPoint.$div(bytes16A, bytes16B)).to.be.equal(bytes16C);
        });

        it("max / 1⁻ that OFs", async function () {
            const bytes16A = MAX_FP;
            const bytes16B = "0x3ffefffffffffffffffffffffffffff0"; // because x/(1-ε) ≥ x(1+ε)
            const bytes16C = INF_FP;

            expect(await floatingPoint.$div(bytes16A, bytes16B)).to.be.equal(bytes16C);
        });

        it("random pairs that barely overflow", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomUnsignedBytes16();
                let bytes16B = mulBytes16(MAX_FP, bytes16A, true).bytes16;
                let bytes16C = bytes16B === INF_FP ? INF_FP : divBytes16(bytes16A, bytes16B).bytes16;

                if (bytes16C === INF_FP) await expect(floatingPoint.$div(bytes16A, bytes16B)).to.be.reverted;
                else expect(await floatingPoint.$div(bytes16A, bytes16B)).to.be.equal(bytes16C);

                bytes16B = mulBytes16(MAX_FP, bytes16A, false).bytes16;
                bytes16C = bytes16B === INF_FP ? INF_FP : divBytes16(bytes16A, bytes16B).bytes16;

                if (bytes16C === INF_FP) await expect(floatingPoint.$div(bytes16A, bytes16B)).to.be.reverted;
                else expect(await floatingPoint.$div(bytes16A, bytes16B)).to.be.equal(bytes16C);
            }
        });
    });

    describe("inv", async function () {
        it("random floating point numbers", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomSignedBytes16();
                const bytes16B = divBytes16(ONE_FP, bytes16A).bytes16;

                const fracA = bytes16ToFraction(bytes16A);

                if (fracA.num.lt(0)) await expect(floatingPoint.$inv(bytes16A)).to.be.reverted;
                else expect(await floatingPoint.$inv(bytes16A)).to.be.equal(bytes16B);
            }
        });

        it("rounding error is bounded", async function () {
            for (let i = 0; i < N; i++) {
                let bytes16A;
                let num, den, bytes16;
                do {
                    ({ num, den, bytes16 } = divBytes16(ONE_FP, (bytes16A = randomUnsignedBytes16())));
                } while (bytes16 === INF_FP || bytes16 === ZERO_FP);

                const fracB = bytes16ToFraction(await floatingPoint.$inv(bytes16A));

                expect(fracB.num.mul(den).mul(Two.pow(112))).to.be.within(
                    fracB.den.mul(num).mul(Two.pow(112).sub(1)),
                    fracB.den.mul(num).mul(Two.pow(112))
                );
            }
        });

        it("0", async function () {
            const bytes16A = ZERO_FP;

            await expect(floatingPoint.$inv(bytes16A)).to.be.reverted;
        });

        it("inf", async function () {
            const bytes16A = INF_FP;

            await expect(floatingPoint.$inv(bytes16A)).to.be.reverted;
        });

        it("almost underflows", async function () {
            const bytes16A = "0x7ffd0000000000000000000000000000";
            const bytes16B = ZERO_FP;

            expect(await floatingPoint.$inv(bytes16A)).to.not.be.equal(bytes16B);
        });

        it("barely underflows", async function () {
            const bytes16A = "0x7ffd0000000000000000000000000001";
            const bytes16B = ZERO_FP;

            expect(await floatingPoint.$inv(bytes16A)).to.be.equal(bytes16B);
        });
    });

    describe("mulu", async function () {
        it("random pairs of floating point numbers", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomSignedBytes16();
                const uintB = randomBigUint();
                const fracA = bytes16ToFraction(bytes16A);
                const uintC = fracA.num.mul(uintB).div(fracA.den);

                if (fracA.num.lt(0) || uintC.gt(MaxUint256))
                    await expect(floatingPoint.$mulu(bytes16A, uintB)).to.be.reverted;
                else expect(await floatingPoint.$mulu(bytes16A, uintB)).to.be.equal(uintC);
            }
        });

        it("random pairs of floating point numbers within UInt range", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomSignedBytes16WithinUIntRange();
                const uintB = randomBigUint();
                const fracA = bytes16ToFraction(bytes16A);
                const num = fracA.num.mul(uintB);
                const { den } = fracA;
                const uintC = num.div(den);

                if (fracA.num.lt(0) || uintC.gt(MaxUint256))
                    await expect(floatingPoint.$mulu(bytes16A, uintB)).to.be.reverted;
                else expect(await floatingPoint.$mulu(bytes16A, uintB)).to.be.equal(uintC);
            }
        });

        it("0 * 0", async function () {
            const bytes16A = ZERO_FP;
            const uintB = Zero;
            const uintC = Zero;

            expect(await floatingPoint.$mulu(bytes16A, uintB)).to.be.equal(uintC);
        });

        it("rounding error is bounded", async function () {
            for (let i = 0; i < N; i++) {
                let bytes16A, fracA;
                let uintB;
                let num, den;
                do {
                    const signifierA = [...Array(28)].map(() => Math.floor(rng() * 16).toString(16)).join("");
                    const expA = (Math.floor(rng() * 128) + 16383 - 64).toString(16).padStart(4, "0");
                    bytes16A = `0x${expA}${signifierA}`;
                    fracA = bytes16ToFraction(bytes16A);
                    uintB = randomBigUint();
                    num = fracA.num.mul(uintB);
                    ({ den } = fracA);
                } while (num.div(den).gt(MaxUint256) || num.div(den).isZero());

                const uintC = await floatingPoint.$mulu(bytes16A, uintB);

                const lenC = bitLengthBigNumber(num.div(den));
                if (lenC < 113) {
                    expect(uintC.mul(den).mul(Two.pow(lenC - 1))).to.be.within(
                        num.mul(Two.pow(lenC - 1).sub(1)),
                        num.mul(Two.pow(lenC - 1))
                    );
                } else
                    expect(uintC.mul(den).mul(Two.pow(112))).to.be.within(
                        num.mul(Two.pow(112).sub(1)),
                        num.mul(Two.pow(112))
                    );
            }
        });

        it("min * 1", async function () {
            const bytes16A = MIN_FP;
            const uintB = One;
            const uintC = Zero;

            expect(await floatingPoint.$mulu(bytes16A, uintB)).to.be.equal(uintC);
        });

        it("1⁻ * 1", async function () {
            const bytes16A = QUASI_ONE_FP;
            const uintB = One;
            const uintC = Zero;

            expect(await floatingPoint.$mulu(bytes16A, uintB)).to.be.equal(uintC);
        });

        it("1 * 1", async function () {
            const bytes16A = ONE_FP;
            const uintB = One;
            const uintC = One;

            expect(await floatingPoint.$mulu(bytes16A, uintB)).to.be.equal(uintC);
        });

        it("2⁻ * 1", async function () {
            const bytes16A = "0x3fffffffffffffffffffffffffffffff";
            const uintB = One;
            const uintC = One;

            expect(await floatingPoint.$mulu(bytes16A, uintB)).to.be.equal(uintC);
        });

        it("1 * MaxUint256", async function () {
            const bytes16A = ONE_FP;
            const uintB = MaxUint256;
            const uintC = MaxUint256;

            expect(await floatingPoint.$mulu(bytes16A, uintB)).to.be.equal(uintC);
        });

        it("1⁺ * MaxUint256", async function () {
            const bytes16A = TAT_LG_ONE_FP;
            const uintB = MaxUint256;
            const uintC = MaxUint256;

            await expect(floatingPoint.$mulu(bytes16A, uintB)).to.be.reverted;
        });

        it("MaxUint256 * 1", async function () {
            const bytes16A = fractionToBytes16(MaxUint256, 1);
            const uintB = One;
            const temp = bytes16ToFraction(bytes16A);
            const uintC = temp.num.div(temp.den);

            expect(await floatingPoint.$mulu(bytes16A, uintB)).to.be.equal(uintC);
        });

        it("MaxUint256⁺ * 1", async function () {
            const bytes16A = fractionToBytes16(MaxUint256, 1, true);
            const uintB = One;

            await expect(floatingPoint.$mulu(bytes16A, uintB)).to.be.reverted;
        });

        it("inf * number", async function () {
            const bytes16A = INF_FP;
            const uintB = randomBigUint();

            await expect(floatingPoint.$mulu(bytes16A, uintB)).to.be.reverted;
        });

        it("inf * 0", async function () {
            const bytes16A = INF_FP;
            const uintB = Zero;

            await expect(floatingPoint.$mulu(bytes16A, uintB)).to.be.reverted;
        });

        it("random pairs that barely overflow", async function () {
            for (let i = 0; i < N; i++) {
                let uintB;
                while ((uintB = randomBigUint()).isZero());
                const uintC = MaxUint256;
                const bytes16A = fractionToBytes16(uintC, uintB, true);

                if (bytes16A === fractionToBytes16(uintC, uintB, false))
                    expect(await floatingPoint.$mulu(bytes16A, uintB)).to.be.equal(uintC);
                else await expect(floatingPoint.$mulu(bytes16A, uintB)).to.be.reverted;
            }
        });
    });

    describe("mulDiv", async function () {
        it("random triples of numbers", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomUnsignedBytes16();
                const uintB = randomBigUint();
                const bytes16C = randomUnsignedBytes16();

                let { num, den } = divBytes16(bytes16A, bytes16C);

                let uintD;
                if (den.isZero() || num.gt(den) || (uintD = num.mul(uintB).div(den)).gt(MaxUint256))
                    await expect(floatingPoint.$mulDiv(bytes16A, uintB, bytes16C)).to.be.reverted;
                else expect(await floatingPoint.$mulDiv(bytes16A, uintB, bytes16C)).to.be.equal(uintD);
            }
        });

        it("rounding error is bounded", async function () {
            for (let i = 0; i < N; i++) {
                let bytes16A, uintB, bytes16C;
                let num, den;
                do {
                    bytes16A = randomUnsignedBytes16WithinUIntRange();
                    const fracA = bytes16ToFraction(bytes16A);
                    uintB = randomBigUint();
                    bytes16C = randomUnsignedBytes16WithinUIntRange();
                    const fracC = bytes16ToFraction(bytes16C);
                    num = fracA.num.mul(uintB).mul(fracC.den);
                    den = fracA.den.mul(fracC.num);
                } while (
                    bytes16C === ZERO_FP ||
                    subBytes16(bytes16A, bytes16C).num.gt(0) ||
                    num.div(den).gt(MaxUint256) ||
                    num.div(den).isZero()
                );

                const uintD = await floatingPoint.$mulDiv(bytes16A, uintB, bytes16C);

                const lenD = bitLengthBigNumber(num.div(den));
                if (lenD < 113) {
                    expect(uintD.mul(den).mul(Two.pow(lenD - 1))).to.be.within(
                        num.mul(Two.pow(lenD - 1).sub(1)),
                        num.mul(Two.pow(lenD - 1))
                    );
                } else
                    expect(uintD.mul(den).mul(Two.pow(112))).to.be.within(
                        num.mul(Two.pow(112).sub(1)),
                        num.mul(Two.pow(112))
                    );
            }
        });

        it("0 * uint / bytes16", async function () {
            const bytes16A = ZERO_FP;
            const uintB = randomBigUint();
            const bytes16C = randomUnsignedBytes16();

            expect(await floatingPoint.$mulDiv(bytes16A, uintB, bytes16C)).to.be.equal(0);
        });

        it("bytes16 * 0 / bytes16", async function () {
            let bytes16A = randomUnsignedBytes16();
            const uintB = 0;
            let bytes16C = randomUnsignedBytes16();
            let temp;
            do {
                bytes16A = randomUnsignedBytes16();
                bytes16C = randomUnsignedBytes16();
                temp = divBytes16(bytes16A, bytes16C, true);
            } while (!temp.num.div(temp.den).isZero());

            expect(await floatingPoint.$mulDiv(bytes16A, uintB, bytes16C)).to.be.equal(0);
        });

        it("1 * MaxUint256 / MaxUint256⁺", async function () {
            const bytes16A = ONE_FP;
            const uintB = MaxUint256;
            const bytes16C = fractionToBytes16(MaxUint256, One, true);

            expect(await floatingPoint.$mulDiv(bytes16A, uintB, bytes16C)).to.be.equal(0);
        });

        it("1 * 1 / 1⁺", async function () {
            const bytes16A = ONE_FP;
            const uintB = One;
            const bytes16C = TAT_LG_ONE_FP;

            expect(await floatingPoint.$mulDiv(bytes16A, uintB, bytes16C)).to.be.equal(0);
        });

        it("neg. * uint / bytes16", async function () {
            let bytes16A = randomSignedBytes16();
            while (bytes16ToFraction((bytes16A = randomSignedBytes16())).num.gte(0));
            const uintB = randomBigUint();
            const bytes16C = randomUnsignedBytes16();

            await expect(floatingPoint.$mulDiv(bytes16A, uintB, bytes16C)).to.be.reverted;
        });

        it("bytes16 * uint / neg.", async function () {
            const bytes16A = randomUnsignedBytes16();
            const uintB = randomBigUint();
            let bytes16C;
            while (bytes16ToFraction((bytes16C = randomSignedBytes16())).num.gte(0));

            await expect(floatingPoint.$mulDiv(bytes16A, uintB, bytes16C)).to.be.reverted;
        });

        it("0 * uint / 0", async function () {
            const bytes16A = ZERO_FP;
            const uintB = randomBigUint();
            let bytes16C = ZERO_FP;

            await expect(floatingPoint.$mulDiv(bytes16A, uintB, bytes16C)).to.be.reverted;
        });

        it("bytes16A > bytes16C", async function () {
            let bytes16A = randomUnsignedBytes16();
            const uintB = 0;
            let bytes16C = randomUnsignedBytes16();
            let temp;
            do {
                bytes16A = randomUnsignedBytes16();
                bytes16C = randomUnsignedBytes16();
                temp = divBytes16(bytes16A, bytes16C, true);
            } while (temp.num.div(temp.den).isZero());

            await expect(floatingPoint.$mulDiv(bytes16A, uintB, bytes16C)).to.be.reverted;
        });

        it("bytes16A > bytes16C", async function () {
            let bytes16A = randomUnsignedBytes16();
            const uintB = 0;
            let bytes16C = randomUnsignedBytes16();
            let temp;
            do {
                bytes16A = randomUnsignedBytes16();
                bytes16C = randomUnsignedBytes16();
                temp = divBytes16(bytes16A, bytes16C, true);
            } while (temp.num.div(temp.den).isZero());

            await expect(floatingPoint.$mulDiv(bytes16A, uintB, bytes16C)).to.be.reverted;
        });

        it("1⁺ * 1 / 1", async function () {
            const bytes16A = TAT_LG_ONE_FP;
            const uintB = One;
            const bytes16C = ONE_FP;

            await expect(floatingPoint.$mulDiv(bytes16A, uintB, bytes16C)).to.be.reverted;
        });

        it("bytes16 * uint * inf", async function () {
            const bytes16A = randomUnsignedBytes16();
            const uintB = MaxUint256;
            const bytes16C = INF_FP;

            await expect(floatingPoint.$mulDiv(bytes16A, uintB, bytes16C)).to.be.reverted;
        });

        it("inf * uint * inf", async function () {
            const bytes16A = INF_FP;
            const uintB = MaxUint256;
            const bytes16C = INF_FP;

            await expect(floatingPoint.$mulDiv(bytes16A, uintB, bytes16C)).to.be.reverted;
        });

        it("1 * MaxUint256 / 1", async function () {
            const bytes16A = ONE_FP;
            const uintB = MaxUint256;
            const bytes16C = ONE_FP;

            expect(await floatingPoint.$mulDiv(bytes16A, uintB, bytes16C)).to.be.equal(MaxUint256);
        });

        it("random triples that almost zero", async function () {
            for (let i = 0; i < N; i++) {
                let bytes16A, uintB, bytes16C;
                let fracA;
                do {
                    bytes16A = randomUnsignedBytes16();
                    fracA = bytes16ToFraction(bytes16A);
                    uintB = randomBigUint();
                    bytes16C = fractionToBytes16(fracA.num.mul(uintB), fracA.den, false);
                } while (bytes16C === INF_FP || bytes16C === ZERO_FP);

                const bytes16D = fractionToBytes16(fracA.num.mul(uintB), fracA.den, true);

                if (bytes16C === bytes16D)
                    expect(await floatingPoint.$mulDiv(bytes16A, uintB, bytes16C)).to.be.equal(1);
                else {
                    expect(await floatingPoint.$mulDiv(bytes16A, uintB, bytes16C)).to.be.gte(1);
                    expect(await floatingPoint.$mulDiv(bytes16A, uintB, bytes16D)).to.be.equal(0);
                }
            }
        });
    });

    describe("divu", async function () {
        it("random pairs of uint", async function () {
            for (let i = 0; i < N; i++) {
                const uintA = randomBigUint();
                let uintB;
                while ((uintB = randomBigUint()).isZero());
                const bytes16C = await floatingPoint.$divu(uintA, uintB);

                expect(fractionToBytes16(uintA, uintB)).to.be.equal(bytes16C);

                const { num, den } = bytes16ToFraction(bytes16C);
                if (exponentOfBytes16(bytes16C).exponent <= 16383 + 112)
                    expect(uintA.div(uintB)).to.be.equal(num.div(den));
            }
        });

        it("rounding error is bounded", async function () {
            for (let i = 0; i < N; i++) {
                const uintA = randomBigUint();
                let uintB;
                while ((uintB = randomBigUint()).isZero());

                const fracC = bytes16ToFraction(await floatingPoint.$divu(uintA, uintB));

                expect(fracC.num.mul(uintB).mul(Two.pow(112))).to.be.within(
                    uintA.mul(fracC.den).mul(Two.pow(112).sub(1)),
                    uintA.mul(fracC.den).mul(Two.pow(112))
                );
            }
        });

        it("0 / 0", async function () {
            const uintA = Zero;
            const uintB = Zero;

            await expect(floatingPoint.$divu(uintA, uintB)).to.be.reverted;
        });

        it("number / 0", async function () {
            const uintA = randomBigUint();
            const uintB = Zero;

            await expect(floatingPoint.$divu(uintA, uintB)).to.be.reverted;
        });

        it("0 / number", async function () {
            const uintA = Zero;
            const uintB = randomBigUint();
            const bytes16C = ZERO_FP;

            expect(await floatingPoint.$divu(uintA, uintB)).to.be.equal(bytes16C);
        });

        it("max / number", async function () {
            const uintA = MaxUint256;
            const uintB = randomBigUint();
            const bytes16C = fractionToBytes16(uintA, uintB);

            expect(await floatingPoint.$divu(uintA, uintB)).to.be.equal(bytes16C);
        });

        it("max / max", async function () {
            const uintA = MaxUint256;
            const uintB = MaxUint256;
            const bytes16C = ONE_FP;

            expect(await floatingPoint.$divu(uintA, uintB)).to.be.equal(bytes16C);
        });
    });

    describe("mulDivu", async function () {
        it("random triples of numbers", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomSignedBytes16();
                const uintB = randomBigUint();
                const uintC = randomBigUint();

                let fracA = bytes16ToFraction(bytes16A);
                const bytes16D = fractionToBytes16(fracA.num.mul(uintB), fracA.den.mul(uintC));

                if (bytes16D === INF_FP || fracA.num.lt(0) || uintC.eq(Zero))
                    await expect(floatingPoint.$mulDivu(bytes16A, uintB, uintC)).to.be.reverted;
                else expect(await floatingPoint.$mulDivu(bytes16A, uintB, uintC)).to.be.equal(bytes16D);
            }
        });

        it("rounding error is bounded", async function () {
            for (let i = 0; i < N; i++) {
                let bytes16A, uintB, uintC;
                let num, den;
                do {
                    bytes16A = randomUnsignedBytes16WithinUIntRange();
                    ({ num, den } = bytes16ToFraction(bytes16A));
                    uintB = randomBigUint();
                    uintC = randomBigUint();
                    den = den.mul(uintC);
                } while (uintC.isZero() || bitLengthBigNumber((num = num.mul(uintB)).div(den)) > 16383);

                const fracD = bytes16ToFraction(await floatingPoint.$mulDivu(bytes16A, uintB, uintC));
                expect(fracD.num.mul(den).mul(Two.pow(112))).to.be.within(
                    fracD.den.mul(num).mul(Two.pow(112).sub(1)),
                    fracD.den.mul(num).mul(Two.pow(112))
                );
            }
        });

        it("0 * 0 / 0", async function () {
            const bytes16A = ZERO_FP;
            const uintB = Zero;
            const uintC = Zero;

            await expect(floatingPoint.$mulDivu(bytes16A, uintB, uintC)).to.be.reverted;
        });

        it("0 * uint / uint", async function () {
            const bytes16A = ZERO_FP;
            const uintB = randomBigUint();
            const uintC = randomBigUint();
            const bytes16D = ZERO_FP;

            expect(await floatingPoint.$mulDivu(bytes16A, uintB, uintC)).to.be.equal(bytes16D);
        });

        it("bytes16 * 0 / uint", async function () {
            let bytes16A = randomUnsignedBytes16();
            const uintB = 0;
            const uintC = randomBigUint();
            const bytes16D = ZERO_FP;

            expect(await floatingPoint.$mulDivu(bytes16A, uintB, uintC)).to.be.equal(bytes16D);
        });

        it("bytes16 * uint / 0", async function () {
            const bytes16A = ZERO_FP;
            const uintB = randomBigUint();
            const uintC = Zero;

            await expect(floatingPoint.$mulDivu(bytes16A, uintB, uintC)).to.be.reverted;
        });

        it("1 * 1 / 1", async function () {
            const bytes16A = ONE_FP;
            const uintB = One;
            const uintC = One;
            const bytes16D = ONE_FP;

            expect(await floatingPoint.$mulDivu(bytes16A, uintB, uintC)).to.be.equal(bytes16D);
        });

        it("1 * MaxUint256 / MaxUint256⁺", async function () {
            const bytes16A = ONE_FP;
            const uintB = MaxUint256;
            const uintC = MaxUint256;
            const bytes16D = ONE_FP;

            expect(await floatingPoint.$mulDivu(bytes16A, uintB, uintC)).to.be.equal(bytes16D);
        });

        it("MaxUint256 * 1 / MaxUint256⁺", async function () {
            const uintB = One;
            const uintC = MaxUint256;

            let bytes16A = fractionToBytes16(MaxUint256, One, false);
            let bytes16D = await floatingPoint.$mulDivu(bytes16A, uintB, uintC);
            let fracD = bytes16ToFraction(bytes16D);
            expect(fracD.num).to.be.lt(fracD.den);

            bytes16A = fractionToBytes16(MaxUint256, One, true);
            bytes16D = await floatingPoint.$mulDivu(bytes16A, uintB, uintC);
            fracD = bytes16ToFraction(bytes16D);
            expect(fracD.num).to.be.gte(fracD.den);
        });

        it("neg. * uint / uint", async function () {
            let bytes16A = randomSignedBytes16();
            while (bytes16ToFraction((bytes16A = randomSignedBytes16())).num.gte(0));
            const uintB = randomBigUint();
            const uintC = randomBigUint();

            await expect(floatingPoint.$mulDivu(bytes16A, uintB, uintC)).to.be.reverted;
        });

        it("inf * uint / uint that OF", async function () {
            let bytes16A = INF_FP;
            const uintB = randomBigUint();
            const uintC = randomBigUint();

            await expect(floatingPoint.$mulDivu(bytes16A, uintB, uintC)).to.be.reverted;
        });

        it("bytes16 * uint / uint", async function () {
            const uintB = MaxUint256;
            const uintC = MaxUint256.sub(1);

            const fracMax = bytes16ToFraction(MAX_FP);
            const bytes16A = fractionToBytes16(fracMax.num.mul(uintC), fracMax.den.mul(uintB), true);

            expect(await floatingPoint.$mulDivu(bytes16A, uintB, uintC)).to.be.equal(MAX_FP);
        });

        it("random triples that almost zero", async function () {
            for (let i = 0; i < N; i++) {
                let uintB;
                while ((uintB = randomBigUint()).isZero()); // uintB != 0
                let uintC;
                while ((uintC = randomBigUint()).isZero()); // uintC != 0
                const bytes16ARoundedDown = fractionToBytes16(uintC, uintB, false);
                const bytes16ARoundedUp = fractionToBytes16(uintC, uintB, true);

                if (bytes16ARoundedDown === bytes16ARoundedUp)
                    expect(await floatingPoint.$mulDivu(bytes16ARoundedDown, uintB, uintC)).to.be.equal(ONE_FP);
                else {
                    let fracD = bytes16ToFraction(await floatingPoint.$mulDivu(bytes16ARoundedDown, uintB, uintC));
                    expect(fracD.num).to.be.lt(fracD.den);

                    fracD = bytes16ToFraction(await floatingPoint.$mulDivu(bytes16ARoundedUp, uintB, uintC));
                    expect(fracD.num).to.be.gte(fracD.den);
                }
            }
        });

        it("random triples that almost OF", async function () {
            for (let i = 0; i < N; i++) {
                const fracMax = bytes16ToFraction(MAX_FP);
                let uintB, uintC;
                while ((uintB = randomBigUint()).lt((uintC = randomBigUint())) || uintC.isZero()); // uintB > unitC > 0

                let bytes16A = fractionToBytes16(fracMax.num.mul(uintC), fracMax.den.mul(uintB), false);
                await expect(floatingPoint.$mulDivu(bytes16A, uintB, uintC)).to.not.be.reverted;

                bytes16A = fractionToBytes16(fracMax.num.mul(uintC), fracMax.den.mul(uintB), true);
                const fracA = bytes16ToFraction(bytes16A);

                if (fractionToBytes16(fracA.num.mul(uintB), fracA.den.mul(uintC)) === MAX_FP)
                    expect(await floatingPoint.$mulDivu(bytes16A, uintB, uintC)).to.be.equal(MAX_FP);
                else await expect(floatingPoint.$mulDivu(bytes16A, uintB, uintC)).to.be.reverted;
            }
        });
    });

    describe("mulDivuUp", async function () {
        it("random triples of numbers", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomSignedBytes16();
                const uintB = randomBigUint();
                const uintC = randomBigUint();

                let fracA = bytes16ToFraction(bytes16A);
                const bytes16D = fractionToBytes16(fracA.num.mul(uintB), fracA.den.mul(uintC), true);

                if (bytes16D === INF_FP || fracA.num.lt(0) || uintC.eq(Zero))
                    await expect(floatingPoint.$mulDivuUp(bytes16A, uintB, uintC)).to.be.reverted;
                else expect(await floatingPoint.$mulDivuUp(bytes16A, uintB, uintC)).to.be.equal(bytes16D);
            }
        });

        it("rounding error is bounded", async function () {
            for (let i = 0; i < N; i++) {
                let bytes16A, uintB, uintC;
                let num, den;
                do {
                    bytes16A = randomUnsignedBytes16WithinUIntRange();
                    ({ num, den } = bytes16ToFraction(bytes16A));
                    uintB = randomBigUint();
                    uintC = randomBigUint();
                    den = den.mul(uintC);
                } while (uintC.isZero() || bitLengthBigNumber((num = num.mul(uintB)).sub(1).div(den).add(1)) > 16383);

                const fracD = bytes16ToFraction(await floatingPoint.$mulDivuUp(bytes16A, uintB, uintC));
                expect(fracD.num.mul(den).mul(Two.pow(112))).to.be.within(
                    fracD.den.mul(num).mul(Two.pow(112)),
                    fracD.den.mul(num).mul(Two.pow(112).add(1))
                );
            }
        });

        it("0 * 0 / 0", async function () {
            const bytes16A = ZERO_FP;
            const uintB = Zero;
            const uintC = Zero;

            await expect(floatingPoint.$mulDivuUp(bytes16A, uintB, uintC)).to.be.reverted;
        });

        it("0 * uint / uint", async function () {
            const bytes16A = ZERO_FP;
            const uintB = randomBigUint();
            const uintC = randomBigUint();
            const bytes16D = ZERO_FP;

            expect(await floatingPoint.$mulDivuUp(bytes16A, uintB, uintC)).to.be.equal(bytes16D);
        });

        it("bytes16 * 0 / uint", async function () {
            let bytes16A = randomUnsignedBytes16();
            const uintB = 0;
            const uintC = randomBigUint();
            const bytes16D = ZERO_FP;

            expect(await floatingPoint.$mulDivuUp(bytes16A, uintB, uintC)).to.be.equal(bytes16D);
        });

        it("bytes16 * uint / 0", async function () {
            const bytes16A = ZERO_FP;
            const uintB = randomBigUint();
            const uintC = Zero;

            await expect(floatingPoint.$mulDivuUp(bytes16A, uintB, uintC)).to.be.reverted;
        });

        it("1 * 1 / 1", async function () {
            const bytes16A = ONE_FP;
            const uintB = One;
            const uintC = One;
            const bytes16D = ONE_FP;

            expect(await floatingPoint.$mulDivuUp(bytes16A, uintB, uintC)).to.be.equal(bytes16D);
        });

        it("1⁻ * max / (max-1)", async function () {
            const bytes16A = QUASI_ONE_FP;
            const uintB = MaxUint256;
            const uintC = MaxUint256.sub(1);
            const bytes16D = ONE_FP;

            expect(await floatingPoint.$mulDivuUp(bytes16A, uintB, uintC)).to.be.equal(bytes16D);
        });

        it("1 * MaxUint256 / MaxUint256⁺", async function () {
            const bytes16A = ONE_FP;
            const uintB = MaxUint256;
            const uintC = MaxUint256;
            const bytes16D = ONE_FP;

            expect(await floatingPoint.$mulDivuUp(bytes16A, uintB, uintC)).to.be.equal(bytes16D);
        });

        it("MaxUint256 * 1 / MaxUint256⁺", async function () {
            const uintB = One;
            const uintC = MaxUint256;

            let bytes16A = fractionToBytes16(MaxUint256, One, false);
            let bytes16D = await floatingPoint.$mulDivuUp(bytes16A, uintB, uintC);
            let fracD = bytes16ToFraction(bytes16D);
            expect(fracD.num).to.be.lte(fracD.den);

            bytes16A = fractionToBytes16(MaxUint256, One, true);
            bytes16D = await floatingPoint.$mulDivuUp(bytes16A, uintB, uintC);
            fracD = bytes16ToFraction(bytes16D);
            expect(fracD.num).to.be.gt(fracD.den);
        });

        it("neg. * uint / uint", async function () {
            let bytes16A = randomSignedBytes16();
            while (bytes16ToFraction((bytes16A = randomSignedBytes16())).num.gte(0));
            let uintB;
            while ((uintB = randomBigUint()).isZero());
            const uintC = randomBigUint();

            await expect(floatingPoint.$mulDivuUp(bytes16A, uintB, uintC)).to.be.reverted;
        });

        it("inf * uint / uint that OF", async function () {
            let bytes16A = INF_FP;
            const uintB = randomBigUint();
            const uintC = randomBigUint();

            await expect(floatingPoint.$mulDivuUp(bytes16A, uintB, uintC)).to.be.reverted;
        });

        it("max * uint / uint", async function () {
            let bytes16A = MAX_FP;
            const uintB = MaxUint256;
            const uintC = MaxUint256.sub(1);

            await expect(floatingPoint.$mulDivuUp(bytes16A, uintB, uintC)).to.be.reverted;

            const fracMax = bytes16ToFraction(MAX_FP);
            bytes16A = fractionToBytes16(fracMax.num.mul(uintC), fracMax.den.mul(uintB), true);
            await expect(floatingPoint.$mulDivuUp(bytes16A, uintB, uintC)).to.be.reverted;
        });

        it("random triples that almost zero", async function () {
            for (let i = 0; i < N; i++) {
                let uintB;
                while ((uintB = randomBigUint()).isZero()); // uintB != 0
                let uintC;
                while ((uintC = randomBigUint()).isZero()); // uintC != 0
                const bytes16ARoundedDown = fractionToBytes16(uintC, uintB, false);
                const bytes16ARoundedUp = fractionToBytes16(uintC, uintB, true);

                if (bytes16ARoundedDown === bytes16ARoundedUp)
                    expect(await floatingPoint.$mulDivuUp(bytes16ARoundedDown, uintB, uintC)).to.be.equal(ONE_FP);
                else {
                    let fracD = bytes16ToFraction(await floatingPoint.$mulDivuUp(bytes16ARoundedDown, uintB, uintC));
                    expect(fracD.num).to.be.lte(fracD.den);

                    fracD = bytes16ToFraction(await floatingPoint.$mulDivuUp(bytes16ARoundedUp, uintB, uintC));
                    expect(fracD.num).to.be.gt(fracD.den);
                }
            }
        });

        it("random triples that almost OF", async function () {
            for (let i = 0; i < N; i++) {
                let uintB, uintC;
                while ((uintB = randomBigUint()).lte((uintC = randomBigUint())) || uintC.isZero()); // uintB > unitC > 0
                const fracMax = bytes16ToFraction(MAX_FP);

                let bytes16A = fractionToBytes16(fracMax.num.mul(uintC), fracMax.den.mul(uintB), false);

                const bytes16D = await floatingPoint.$mulDivuUp(bytes16A, uintB, uintC);
                const temp = bytes16ToFraction(bytes16D);
                expect(temp.num.mul(fracMax.den)).to.be.lte(temp.den.mul(fracMax.num));

                bytes16A = fractionToBytes16(fracMax.num.mul(uintC), fracMax.den.mul(uintB), true);
                await expect(floatingPoint.$mulDivuUp(bytes16A, uintB, uintC)).to.be.reverted;
            }
        });
    });

    describe("pow_2", async function () {
        it("random numbers", async function () {
            for (let i = 0; i < N; i++) {
                const bytes16A = randomSignedBytes16();
                const fracA = bytes16ToFraction(bytes16A);
                const numberB = 2 ** bytes16ToNumber(bytes16A);

                if (fracA.num.lt(fracA.den.mul(16384)))
                    expect(bytes16ToNumber(await floatingPoint.$pow_2(bytes16A))).to.be.closeTo(
                        numberB,
                        numberB / 1e10
                    );
                else await expect(floatingPoint.$pow_2(bytes16A)).to.be.reverted;
            }
        });

        it("0", async function () {
            const bytes16A = ZERO_FP;
            const bytes16B = ONE_FP;

            expect(await floatingPoint.$pow_2(bytes16A)).to.be.equal(bytes16B);
        });

        it("bytes16 that barely OF", async function () {
            let bytes16A = fractionToBytes16(16384, 1);
            await expect(floatingPoint.$pow_2(bytes16A)).to.be.reverted;

            bytes16A = fractionToBytes16(Two.pow(113).mul(16384), Two.pow(113).add(1));
            await expect(floatingPoint.$pow_2(bytes16A)).to.not.be.reverted;
        });

        it("inf", async function () {
            const bytes16A = INF_FP;

            await expect(floatingPoint.$pow_2(bytes16A)).to.be.reverted;
        });
    });

    describe("pow", async function () {
        it("random pairs of FP", async function () {
            for (let i = 0; i < N; i++) {
                let bytes16A, fracA, numberA;
                do {
                    bytes16A = randomSignedBytes16();
                    fracA = bytes16ToFraction(bytes16A);
                    numberA = bytes16ToNumber(bytes16A);
                } while (numberA === 0); // If numberA === 0 but bytes16A !== ZERO_FP, I will get a failed test incorrectly

                const bytes16B = randomSignedBytes16();
                const fracB = bytes16ToFraction(bytes16B);
                const numberB = bytes16ToNumber(bytes16B);

                if (numberA === 0)
                    if (
                        fracA.num.gt(fracA.den) ||
                        fracA.num.lt(0) ||
                        fracB.num.lt(0) ||
                        numberB * Math.log2(numberA) >= 16384
                    )
                        await expect(floatingPoint.$pow(bytes16A, bytes16B)).to.be.reverted;
                    else {
                        const numberC = numberA ** numberB;
                        expect(bytes16ToNumber(await floatingPoint.$pow(bytes16A, bytes16B))).to.be.closeTo(
                            numberC,
                            numberC / 1e10
                        );
                    }
            }
        });

        it("random pairs of FP with realistic values", async function () {
            for (let i = 0; i < N; i++) {
                const numberA = rng();
                const numberB = 2 ** (Math.floor(256 * rng()) - 128);
                const bytes16A = numberToBytes16(numberA);
                const bytes16B = numberToBytes16(numberB);
                const numberC = numberA ** numberB;

                expect(bytes16ToNumber(await floatingPoint.$pow(bytes16A, bytes16B))).to.be.closeTo(
                    numberC,
                    numberC / 1e10
                );
            }
        });

        it("0 ** 0", async function () {
            const bytes16A = ZERO_FP;
            const bytes16B = ZERO_FP;
            const bytes16C = ONE_FP;

            expect(await floatingPoint.$pow(bytes16A, bytes16B)).to.be.equal(bytes16C);
        });

        it("0 ** 1", async function () {
            const bytes16A = ZERO_FP;
            const bytes16B = ONE_FP;
            const bytes16C = ZERO_FP;

            expect(await floatingPoint.$pow(bytes16A, bytes16B)).to.be.equal(bytes16C);
        });

        it("1 ** 0", async function () {
            const bytes16A = ONE_FP;
            const bytes16B = ZERO_FP;
            const bytes16C = ONE_FP;

            expect(await floatingPoint.$pow(bytes16A, bytes16B)).to.be.equal(bytes16C);
        });

        it(".5 ** 2", async function () {
            const bytes16A = fractionToBytes16(1, 2);
            const bytes16B = fractionToBytes16(2, 1);
            const bytes16C = fractionToBytes16(1, 4);

            expect(await floatingPoint.$pow(bytes16A, bytes16B)).to.be.equal(bytes16C);
        });

        it("bytes16 ** neg", async function () {
            const bytes16A = numberToBytes16(rng());
            let bytes16B = randomSignedBytes16();
            while (bytes16ToFraction((bytes16B = randomSignedBytes16())).num.gte(0));

            await expect(floatingPoint.$pow(bytes16A, bytes16B)).to.be.reverted;
        });

        it("neg ** bytes16", async function () {
            let bytes16A = randomSignedBytes16();
            while (bytes16ToFraction((bytes16A = randomSignedBytes16())).num.gte(0));
            const bytes16B = numberToBytes16(rng());

            await expect(floatingPoint.$pow(bytes16A, bytes16B)).to.be.reverted;
        });

        it("1⁺ ** bytes16", async function () {
            const bytes16A = TAT_LG_ONE_FP;
            const numberB = 2 ** (Math.floor(256 * rng()) - 128);
            const bytes16B = numberToBytes16(numberB);

            await expect(floatingPoint.$pow(bytes16A, bytes16B)).to.be.reverted;
        });
    });

    describe("function vs. function", async function () {
        describe("add vs. addUp", async function () {
            it("⌊a+b⌋≤⌈a+b⌉", async function () {
                for (let i = 0; i < N; i++) {
                    const bytes16A = randomUnsignedBytes16();
                    const bytes16B = randomUnsignedBytes16();
                    try {
                        const fracCRoundedDown = bytes16ToFraction(await floatingPoint.$add(bytes16A, bytes16B));
                        const fracCRoundedUp = bytes16ToFraction(await floatingPoint.$addUp(bytes16A, bytes16B));
                        expect(fracCRoundedDown.num.mul(fracCRoundedUp.den)).to.be.lte(
                            fracCRoundedUp.num.mul(fracCRoundedDown.den)
                        );
                    } catch (error) {
                        if (error.code !== "CALL_EXCEPTION") throw error;
                    }
                }
            });
            it("exponents differ", async function () {
                for (let i = 0; i < N; i++) {
                    const exp = Math.floor(rng() * 32652) + 113;
                    const bytes16C = `0x${exp.toString(16).padStart(4, "0")}ffffffffffffffffffffffffffff`; // We are aiming for the sum to be this
                    const Nshift = 1 + Math.floor(rng() * 113);
                    let signifierB;
                    while (
                        (signifierB = BigNumber.from(
                            `0x${[...Array(28)].map(() => Math.floor(rng() * 16).toString(16)).join("")}`
                        ))
                            .mask(Nshift)
                            .isZero()
                    ); // Make sure last Nshift bits are not 0 so that rounding up or down produces different # of bits
                    const bytes16B = `0x${(exp - Nshift).toString(16).padStart(4, "0")}${signifierB
                        .toHexString()
                        .slice(2)
                        .padStart(28, "0")}`;
                    const bytes16A = subBytes16(bytes16C, bytes16B, true).bytes16;
                    expect(exponentOfBytes16(await floatingPoint.$add(bytes16A, bytes16B)).exponent).to.be.equal(
                        exponentOfBytes16(await floatingPoint.$addUp(bytes16A, bytes16B)).exponent - 1
                    );
                }
            });
        });
        describe("sub vs. subUp", async function () {
            it("⌊a-b⌋≤⌈a-b⌉", async function () {
                for (let i = 0; i < N; i++) {
                    let bytes16A, bytes16B;
                    while (
                        subBytes16((bytes16A = randomUnsignedBytes16()), (bytes16B = randomUnsignedBytes16())).num.lt(0)
                    ); // bytes16A > bytes16B
                    try {
                        const fracCRoundedDown = bytes16ToFraction(await floatingPoint.$sub(bytes16A, bytes16B));
                        const fracCRoundedUp = bytes16ToFraction(await floatingPoint.$subUp(bytes16A, bytes16B));
                        expect(fracCRoundedDown.num.mul(fracCRoundedUp.den)).to.be.lte(
                            fracCRoundedUp.num.mul(fracCRoundedDown.den)
                        );
                    } catch (error) {
                        if (error.code !== "CALL_EXCEPTION") throw error;
                    }
                }
            });
            it("exponents differ", async function () {
                for (let i = 0; i < N; i++) {
                    let signifierA = BigNumber.from(
                        `0x${[...Array(28)].map(() => Math.floor(rng() * 16).toString(16)).join("")}`
                    );
                    let Nshift = Math.floor(112 * rng());
                    signifierA = signifierA.mask(112 - Nshift); // The signifier of bytes16A is led by a sequence of 1's
                    if (signifierA.isZero()) signifierA = One;
                    const expo = Math.floor(rng() * 32654) + 113;
                    const bytes16A = `0x${expo.toString(16).padStart(4, "0")}${signifierA
                        .toHexString()
                        .slice(2)
                        .padStart(28, "0")}`;
                    while (signifierA.mul(Two.pow(++Nshift)).lt(Two.pow(112))); // This is done to ensure bytes16B's signifier first bit is 1 (as required by IEEE standard)
                    let nuissance; // The nuissance is added to make sub() and subUp different in exponent
                    while (
                        (nuissance = BigNumber.from(
                            `0x${[...Array(28)].map(() => Math.floor(rng() * 16).toString(16)).join("")}`
                        ).mask(Nshift)).isZero()
                    );
                    const bytes16B = `0x${(expo - Nshift).toString(16).padStart(4, "0")}${signifierA
                        .mul(Two.pow(Nshift))
                        .mask(112)
                        .add(nuissance)
                        .toHexString()
                        .slice(2)
                        .padStart(28, "0")}`;
                    expect(exponentOfBytes16(await floatingPoint.$sub(bytes16A, bytes16B)).exponent).to.be.equal(
                        exponentOfBytes16(await floatingPoint.$subUp(bytes16A, bytes16B)).exponent - 1
                    );
                }
            });
        });
        describe("mul vs. mulUp", async function () {
            it("⌊a*b⌋≤⌈a*b⌉", async function () {
                for (let i = 0; i < N; i++) {
                    const bytes16A = randomUnsignedBytes16();
                    const bytes16B = randomUnsignedBytes16();
                    try {
                        const fracCRoundedDown = bytes16ToFraction(await floatingPoint.$mul(bytes16A, bytes16B));
                        const fracCRoundedUp = bytes16ToFraction(await floatingPoint.$mulUp(bytes16A, bytes16B));
                        expect(fracCRoundedDown.num.mul(fracCRoundedUp.den)).to.be.lte(
                            fracCRoundedUp.num.mul(fracCRoundedDown.den)
                        );
                    } catch (error) {
                        if (error.code !== "CALL_EXCEPTION") throw error;
                    }
                }
            });
            it("exponents differ", async function () {
                for (let i = 0; i < N; i++) {
                    let shift = Math.floor(rng() * 56 + 57);
                    let expA = Math.floor(rng() * 32764) + 1;
                    const signifierA = Two.pow(shift - 1)
                        .sub(1)
                        .mul(Two.pow(113 - shift))
                        .toHexString()
                        .slice(2);
                    const bytes16A = `0x${expA.toString(16).padStart(4, "0")}${signifierA}`;
                    let signifierB = Zero,
                        j = 0;
                    while (++j * shift <= 112 && (signifierB = signifierB.add(Two.pow(112 - j * shift))));
                    let expB;
                    while (Math.abs(expA + (expB = Math.floor(rng() * 32764) + 1) - 2 * 16383) > 16381);
                    const bytes16B = `0x${expB.toString(16).padStart(4, "0")}${signifierB
                        .toHexString()
                        .slice(2)
                        .padStart(28, "0")}`;
                    expect(exponentOfBytes16(await floatingPoint.$mul(bytes16A, bytes16B)).exponent).to.be.equal(
                        exponentOfBytes16(await floatingPoint.$mulUp(bytes16A, bytes16B)).exponent - 1
                    );
                }
            });
        });
        describe("div vs. mulDiv", async function () {
            it("match with random numbers", async function () {
                for (let i = 0; i < N; i++) {
                    const bytes16A = randomUnsignedBytes16WithinUIntRange();
                    const bytes16B = randomUnsignedBytes16WithinUIntRange();
                    try {
                        const { num, den } = bytes16ToFraction(await floatingPoint.$div(bytes16A, bytes16B));
                        const uintC = num.div(den);
                        expect(uintC).to.be.equal(await floatingPoint.$mulDiv(bytes16A, 1, bytes16B));
                    } catch (error) {
                        if (error.code !== "CALL_EXCEPTION") throw error;
                    }
                }
            });
        });
        describe("mulu vs. mulDivu", async function () {
            it("match with random numbers", async function () {
                for (let i = 0; i < N; i++) {
                    const expA = (Math.floor(rng() * 64) + 16383 - 63).toString(16).padStart(4, "0");
                    const signifierA = [...Array(28)].map(() => Math.floor(rng() * 16).toString(16)).join("");
                    const bytes16A = `0x${expA}${signifierA}`;
                    const uintB = randomBigUint();
                    try {
                        const uintC = await floatingPoint.$mulu(bytes16A, uintB);
                        const bytes16C = await floatingPoint.$mulDivu(bytes16A, uintB, 1);
                        const { num, den } = bytes16ToFraction(bytes16C);
                        if (exponentOfBytes16(bytes16C).exponent <= 16383 + 112)
                            expect(uintC).to.be.equal(num.div(den));
                    } catch (error) {
                        if (error.code !== "CALL_EXCEPTION") throw error;
                    }
                }
            });
        });
        describe("inv vs. div", async function () {
            it("a^-1=1/a", async function () {
                for (let i = 0; i < N; i++) {
                    const bytes16A = randomUnsignedBytes16();
                    expect(await floatingPoint.$inv(bytes16A)).to.be.equal(await floatingPoint.$div(ONE_FP, bytes16A));
                }
            });
        });
        describe("pow vs. pow_2", async function () {
            it("match with random numbers", async function () {
                for (let i = 0; i < N; i++) {
                    const expA = BigNumber.from(-Math.floor(rng() * 128));
                    const expB = BigNumber.from(Math.floor(rng() * 256 - 128));
                    const bytes16A = fractionToBytes16(1, Two.pow(expA.mul(-1)));
                    const [bytes16B, bytes16C] = expB.gte(0)
                        ? [fractionToBytes16(Two.pow(expB), 1), fractionToBytes16(expA.mul(Two.pow(expB)), 1)]
                        : [fractionToBytes16(1, Two.pow(expB.abs())), fractionToBytes16(expA, Two.pow(expB.abs()))];
                    try {
                        expect(await floatingPoint.$pow(bytes16A, bytes16B)).to.be.equal(
                            await floatingPoint.$pow_2(bytes16C)
                        );
                    } catch (error) {
                        if (error.code !== "CALL_EXCEPTION") throw error;
                    }
                }
            });
        });
        describe("add vs. sub : random pairs", async function () {
            it("⌊⌊a+b⌋-b⌋≤a", async function () {
                for (let i = 0; i < N; i++) {
                    const bytes16A = randomUnsignedBytes16();
                    const bytes16B = randomUnsignedBytes16();
                    let sumRoundedDown;
                    try {
                        sumRoundedDown = await floatingPoint.$add(bytes16A, bytes16B);
                        expect(BigNumber.from(await floatingPoint.$sub(sumRoundedDown, bytes16A))).to.be.lte(
                            BigNumber.from(bytes16B)
                        );
                    } catch (error) {
                        if (error.code !== "CALL_EXCEPTION") throw error;
                    }
                }
            });
            it("⌈⌈a+b⌉-b⌉≥a", async function () {
                for (let i = 0; i < N; i++) {
                    const bytes16A = randomUnsignedBytes16();
                    const bytes16B = randomUnsignedBytes16();
                    let sumRoundedUp;
                    try {
                        sumRoundedUp = await floatingPoint.$addUp(bytes16A, bytes16B);
                        expect(BigNumber.from(await floatingPoint.$subUp(sumRoundedUp, bytes16A))).to.be.gte(
                            BigNumber.from(bytes16B)
                        );
                    } catch (error) {
                        if (error.code !== "CALL_EXCEPTION") throw error;
                    }
                }
            });
            it("⌊⌊a-b⌋+b⌋≤a", async function () {
                for (let i = 0; i < N; i++) {
                    const bytes16A = randomUnsignedBytes16();
                    const bytes16B = randomUnsignedBytes16();
                    let subRoundedDown;
                    try {
                        subRoundedDown = await floatingPoint.$sub(bytes16A, bytes16B);
                        expect(BigNumber.from(await floatingPoint.$add(subRoundedDown, bytes16B))).to.be.lte(
                            BigNumber.from(bytes16A)
                        );
                    } catch (error) {
                        if (error.code !== "CALL_EXCEPTION") throw error;
                    }
                }
            });
            it("⌈⌈a-b⌉+b⌉≥a", async function () {
                for (let i = 0; i < N; i++) {
                    const bytes16A = randomUnsignedBytes16();
                    const bytes16B = randomUnsignedBytes16();
                    let subRoundedUp;
                    try {
                        subRoundedUp = await floatingPoint.$subUp(bytes16B, bytes16A);
                        expect(BigNumber.from(await floatingPoint.$addUp(subRoundedUp, bytes16A))).to.be.gte(
                            BigNumber.from(bytes16B)
                        );
                    } catch (error) {
                        if (error.code !== "CALL_EXCEPTION") throw error;
                    }
                }
            });
        });
        describe("mul vs. div", async function () {
            it("⌊⌊a*b⌋/b⌋≤a", async function () {
                for (let i = 0; i < N; i++) {
                    const bytes16A = randomUnsignedBytes16();
                    const bytes16B = randomUnsignedBytes16();
                    let mulRoundedDown;
                    try {
                        mulRoundedDown = await floatingPoint.$mul(bytes16A, bytes16B);
                        expect(BigNumber.from(await floatingPoint.$div(mulRoundedDown, bytes16A))).to.be.lte(
                            BigNumber.from(bytes16B)
                        );
                    } catch (error) {
                        if (error.code !== "CALL_EXCEPTION") throw error;
                    }
                }
            });
            it("⌊⌊a/b⌋*b⌋≤a", async function () {
                for (let i = 0; i < N; i++) {
                    const bytes16A = randomUnsignedBytes16();
                    const bytes16B = randomUnsignedBytes16();
                    let divRoundedDown;
                    try {
                        divRoundedDown = await floatingPoint.$sub(bytes16A, bytes16B);
                        expect(BigNumber.from(await floatingPoint.$add(divRoundedDown, bytes16B))).to.be.lte(
                            BigNumber.from(bytes16A)
                        );
                    } catch (error) {
                        if (error.code !== "CALL_EXCEPTION") throw error;
                    }
                }
            });
        });
    });
});
