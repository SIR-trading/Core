const fs = require("fs");

const Nwords = 220; // Number of salts to generate

async function main() {
    // Read the existing DeployerOfAPE.sol file
    let lines = fs.readFileSync("./src/libraries/DeployerOfAPE.sol", "utf8").split("\n");

    // Remove the existing getSalt function if present
    const startLine = lines.findIndex((line) => line.includes("function getSalt("));
    if (startLine !== -1) {
        let openBraces = 0,
            closeBraces = 0,
            endLine = -1;
        for (let i = startLine; i < lines.length; i++) {
            openBraces += (lines[i].match(/\{/g) || []).length;
            closeBraces += (lines[i].match(/\}/g) || []).length;
            if (openBraces === closeBraces) {
                endLine = i;
                break;
            }
        }
        if (endLine !== -1) {
            lines.splice(startLine, endLine - startLine + 1);
        }
    }

    // Read salts from salts.txt
    const salts = fs
        .readFileSync("salts.txt", "utf8")
        .split("\n")
        .filter((line) => line.trim() !== "")
        .filter((salt, index) => index < Nwords);

    const lastSalt = BigInt(salts[salts.length - 1]) >> BigInt(9 * 24);
    const lastSaltHexStr = `0x${lastSalt.toString(16)}`;

    // Prepare the new getSalt function
    const newGetSaltFunction = `
    function getSalt(uint256 vaultId) internal pure returns (bytes32) {
        uint256 wordId = (vaultId - 1) / 10;
        if (wordId < ${Nwords}) {
            bytes32[] memory salts = new bytes32[](${Nwords});
            ${salts.map((salt, index) => `salts[${index}] = ${salt};`).join("\n            ")}

            bytes32 salt = salts[wordId];
            return bytes32(uint256(uint24(uint256(salt) >> (((vaultId - 1) % 10) * 24))));
        } else {
            return bytes32(${lastSaltHexStr} + vaultId - 10 * ${Nwords});
        }
    }
    `;

    // Insert the new getSalt function before the last closing brace
    const lastClosingBraceIndex = lines.lastIndexOf("}");
    lines.splice(lastClosingBraceIndex, 0, newGetSaltFunction);

    // Write the modified lines back to DeployerOfAPE.sol
    fs.writeFileSync("./src/libraries/DeployerOfAPE.sol", lines.join("\n"), "utf8");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
