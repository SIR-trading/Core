// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {Fees, FullMath} from "src/libraries/Fees.sol";

contract FeesTest is Test {
    /*********************
        MINT TESTS
     *********************/

    function testFuzz_APE(uint16 baseFee, uint256 collateralAmount, int8 leverageTier) public {
        // Constraint leverageTier to supported values
        leverageTier = bound(leverageTier, -3, 2);

        (uint152 collateralFeeFree, uint152 comission) = Fees._hiddenFee(baseFee, collateralAmount, leverageTier);

        assertEq(
            collateralFeeFree + comission,
            collateralAmount,
            "collateral deposited + comission is not equal to collateral in"
        );
    }
}
