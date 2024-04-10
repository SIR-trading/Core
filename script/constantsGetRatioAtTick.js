const Decimal = require("decimal.js");

(async function main() {
    // Set the precision high enough to handle the operations
    Decimal.set({ precision: 100 });

    // Your values as Decimal instances
    const base = new Decimal("1.0001");
    const exponent = new Decimal("1951133415219145403").div(new Decimal("2").pow(42));
    const factor = new Decimal("2").pow(128);

    // Compute the power
    const result = base.pow(exponent).mul(factor);

    // Since you want the result as an integer, you can round it down
    const finalResult = result.floor();

    let bigInt = BigInt(finalResult);

    console.log(bigInt.toString(16));
})();
