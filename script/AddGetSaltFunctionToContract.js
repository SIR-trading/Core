const fs = require("fs");
const hre = require("hardhat");

async function main() {
    // Read the text file
    const DeployerOfAPE = fs.readFileSync("./src/libraries/DeployerOfAPE.sol", "utf8");

    const addGetSaltFunction = ``;

    console.log(DeployerOfAPE);

    // // Perform some editing (in this example, appending " Edited!" to each line)
    // const lines = data.split("\n");
    // const editedLines = lines.map((line) => `${line} Edited!`);
    // const editedData = editedLines.join("\n");

    // // Save the edited content back to the text file
    // fs.writeFileSync("example_edited.txt", editedData, "utf8");
}

// Run the script
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
