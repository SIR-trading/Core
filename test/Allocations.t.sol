// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

// Libraries
import {Addresses} from "src/libraries/Addresses.sol";
import {Contributors} from "src/Contributors.sol";
import {SystemConstants} from "src/libraries/SystemConstants.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

// Contracts
import {Oracle} from "src/Oracle.sol";
import {SystemControl} from "src/SystemControl.sol";
import {SIR} from "src/SIR.sol";
import {APE} from "src/APE.sol";
import {Vault} from "src/Vault.sol";

import "forge-std/Test.sol";
import "forge-std/StdJson.sol";

contract Posthack is Test {
    using stdJson for string;

    string compensationJson;
    string spiceJson;

    constructor() {
        // Get compensated contributors
        compensationJson = vm.readFile(string.concat(vm.projectRoot(), "/contributors/posthack-compensations.json"));

        // Get posthack contributors
        spiceJson = vm.readFile(string.concat(vm.projectRoot(), "/contributors/posthack-contributors.json"));
    }

    function getCompensations(uint256 index) external view returns (address addr, uint256 allocationInBillionParts) {
        string memory idx = vm.toString(index);
        string memory base = string.concat(".allocations[", idx, "]");

        addr = compensationJson.readAddress(string.concat(base, ".address"));
        allocationInBillionParts = compensationJson.readUint(string.concat(base, ".allocationInBillionParts"));
    }

    function getContributors(uint256 index) external view returns (address addr, uint256 allocationInBillionParts) {
        string memory idx = vm.toString(index);
        string memory base = string.concat("[", idx, "]");

        addr = spiceJson.readAddress(string.concat(base, ".address"));
        allocationInBillionParts = spiceJson.readUint(string.concat(base, ".allocationInBillionParts"));
    }
}

contract AllocationsTest is Test {
    using stdJson for string;

    mapping(address => uint256) allocationsInBillionParts;
    address[] public allContributors;
    address treasury;

    Contributors public contributorsContract;
    uint256 public constant YEAR_ISSUANCE = 2_015_000_000 * 10 ** (SystemConstants.SIR_DECIMALS); // 2,015 M SIR per year

    function setUp() public {
        // Helper contract
        Posthack compensations = new Posthack();

        // Get compensated contributors
        uint256 count = 0;
        while (true) {
            try compensations.getCompensations(count) returns (address addr, uint256 allocationInBillionParts) {
                if (allocationsInBillionParts[addr] == 0) {
                    allContributors.push(addr);
                }
                allocationsInBillionParts[addr] += allocationInBillionParts;
            } catch {
                // We reached the end of the array
                break;
            }

            count++;
        }

        // Get posthack contributors
        count = 0;
        while (true) {
            try compensations.getContributors(count) returns (address addr, uint256 allocationInBillionParts) {
                if (allocationsInBillionParts[addr] == 0) {
                    allContributors.push(addr);
                }
                allocationsInBillionParts[addr] += allocationInBillionParts;
            } catch {
                // We reached the end of the array
                break;
            }

            count++;
        }

        // Instantiate contributors contract
        contributorsContract = new Contributors();
    }

    // Test all allocations are greater than 0
    function test_allAddressesHaveAllocations() public view {
        for (uint256 i = 0; i < allContributors.length; i++) {
            uint56 allocation = contributorsContract.getAllocation(allContributors[i]);

            console.log("Address:", allContributors[i], ", allocation:", allocation);
            assertTrue(allocation > 0, "Address has zero allocation");
        }
    }

    // Test there are no weird addresses
    function test_noWeirdAddresses() public view {
        for (uint256 i = 0; i < allContributors.length; i++) {
            address addr = allContributors[i];

            address halfAddr = address(uint160(uint160(addr) & type(uint80).max));
            console.log("Address:", addr, ", right half:", halfAddr);
            assertTrue(halfAddr != address(0), "Address is half-zero");

            halfAddr = address(uint160(uint256(uint160(addr)) >> 80));
            console.log("Address:", addr, ", left half:", halfAddr);
            assertTrue(halfAddr != address(0), "Address is half-zero");
        }
    }

    // Check the sum of all allocations is type(uint56).max
    function test_totalAllocationsIsTypeMax() public view {
        uint256 totalAllocations = 0;

        for (uint256 i = 0; i < allContributors.length; i++) {
            uint56 allocation = contributorsContract.getAllocation(allContributors[i]);
            totalAllocations += allocation;
        }

        assertEq(totalAllocations, type(uint56).max, "Total allocations is not type(uint56).max");
    }

    // Check the allocations match
    function test_allocationsMatch() public view {
        // Validate allocations
        for (uint256 i = 0; i < allContributors.length; i++) {
            address addr = allContributors[i];
            uint256 issuance = (contributorsContract.getAllocation(addr) *
                uint256(SystemConstants.ISSUANCE - SystemConstants.LP_ISSUANCE_FIRST_3_YEARS)) / type(uint56).max;
            uint256 actual = issuance * 365 days;

            uint256 expected = (allocationsInBillionParts[addr] * YEAR_ISSUANCE) / 1e9;

            console.log(addr, actual, expected);
            assertApproxEqRel(actual, expected, 1e12, string.concat("Allocation mismatch for ", vm.toString(addr)));
        }
    }
}

contract ImportantAllocationsTest is Test {
    uint256 public constant YEAR_ISSUANCE = 2_015_000_000 * 10 ** (SystemConstants.SIR_DECIMALS); // 2,015 M SIR per year
    SIR public sir;

    function setUp() public {
        // Deploy oracle
        address oracle = address(new Oracle(Addresses.ADDR_UNISWAPV3_FACTORY));

        // Deploy SystemControl
        address systemControl = address(new SystemControl());

        // Deploy Contributors
        address contributors = address(new Contributors());

        // Deploy SIR
        sir = new SIR(contributors, Addresses.ADDR_WETH, systemControl);

        // Deploy APE implementation
        address apeImplementation = address(new APE());

        // Deploy Vault
        address vault = address(new Vault(systemControl, address(sir), oracle, apeImplementation, Addresses.ADDR_WETH));

        // Initialize SIR
        sir.initialize(vault);
    }

    function test_allocationXatarrer() public {
        address contributor = 0x193AD6d624678b11Bec0C5cFD5723A34725A8433;

        // Skip 5 year
        skip(5 * 365 days);

        // Claim SIR
        uint256 sirRewards = sir.contributorUnclaimedSIR(contributor);

        // Allow for 1 basis point error difference
        assertApproxEqAbs((10_000 * sirRewards) / (3 * YEAR_ISSUANCE), 800, 1);
    }

    function test_allocationMrLivingstream() public {
        address contributor = 0xC58D3aE892A104D663B01194f2EE325CfB5187f2;

        // Skip 5 year
        skip(5 * 365 days);

        // Claim SIR
        uint256 sirRewards = sir.contributorUnclaimedSIR(contributor);

        // Allow for 1 basis point error difference
        assertApproxEqAbs((10_000 * sirRewards) / (3 * YEAR_ISSUANCE), 70, 1);
    }

    function test_allocationRedTiger() public {
        address contributor = 0x0f1b084c7aAf82bB5ad3DE9A1222ecC805b28f85;

        // Skip 5 year
        skip(5 * 365 days);

        // Claim SIR
        uint256 sirRewards = sir.contributorUnclaimedSIR(contributor);

        // Allow for 1 basis point error difference
        assertApproxEqAbs((10_000 * sirRewards) / (3 * YEAR_ISSUANCE), 60, 1);
    }

    function test_allocationTarp() public {
        address contributor = 0xd11f322ad85730Eab11ef61eE9100feE84b63739;

        // Skip 5 year
        skip(5 * 365 days);

        // Claim SIR
        uint256 sirRewards = sir.contributorUnclaimedSIR(contributor);

        // Allow for 1 basis point error difference
        assertApproxEqAbs((10_000 * sirRewards) / (3 * YEAR_ISSUANCE), 200, 1);
    }

    function test_allocationAbstrucked() public {
        address contributor = 0x0e52b591Cbc9AB81c806F303DE8d9a3B0Dc4ea5C;

        // Skip 5 year
        skip(5 * 365 days);

        // Claim SIR
        uint256 sirRewards = sir.contributorUnclaimedSIR(contributor);

        // Allow for 1 basis point error difference
        assertApproxEqAbs((10_000 * sirRewards) / (3 * YEAR_ISSUANCE), 100, 1);
    }

    function test_allocationJames() public {
        address contributor = 0xE24d295154c2D78A7A860E809D57598E551813Bd;

        // Skip 5 year
        skip(5 * 365 days);

        // Claim SIR
        uint256 sirRewards = sir.contributorUnclaimedSIR(contributor);

        // Allow for 1 basis point error difference
        assertApproxEqAbs((10_000 * sirRewards) / (3 * YEAR_ISSUANCE), 40, 1);
    }

    function test_allocationSyzygy() public {
        address contributor = 0xaC4Cb8282d291a74e8C881620E3AFaF6dE98d6aE;

        // Skip 5 year
        skip(5 * 365 days);

        // Claim SIR
        uint256 sirRewards = sir.contributorUnclaimedSIR(contributor);

        // Allow for 1 basis point error difference
        assertApproxEqAbs((10_000 * sirRewards) / (3 * YEAR_ISSUANCE), 30, 1);
    }

    function test_allocationGuild() public {
        address contributor = 0x03eAB50f733c4DbeaE6B120755776eE7c931243C;

        // Skip 5 year
        skip(5 * 365 days);

        // Claim SIR
        uint256 sirRewards = sir.contributorUnclaimedSIR(contributor);

        // Allow for 1 basis point error difference
        assertApproxEqAbs((10_000 * sirRewards) / (3 * YEAR_ISSUANCE), 15, 1);
    }

    function test_allocation0xAlix2() public {
        address contributor = 0xe52a4EaeA658AB94437165CacA01a37A64c0f18e;

        // Skip 5 year
        skip(5 * 365 days);

        // Claim SIR
        uint256 sirRewards = sir.contributorUnclaimedSIR(contributor);

        // Allow for 1 basis point error difference
        assertApproxEqAbs((10_000 * sirRewards) / (3 * YEAR_ISSUANCE), 60, 1);
    }

    function test_allocationDefiCollective() public {
        address contributor = 0x6665E62eF6F6Db29D5F8191fBAC472222C2cc80F;

        // Skip 5 year
        skip(5 * 365 days);

        // Claim SIR
        uint256 sirRewards = sir.contributorUnclaimedSIR(contributor);

        // Allow for 1 basis point error difference
        assertApproxEqAbs((10_000 * sirRewards) / (3 * YEAR_ISSUANCE), 130, 1);
    }

    function test_allocationWhale() public {
        address contributor = 0x7F1CA9Fe9C3728f5c632e5564b2BfF5585BE1748;

        // Skip 5 year
        skip(5 * 365 days);

        // Claim SIR
        uint256 sirRewards = sir.contributorUnclaimedSIR(contributor);

        // Allow for 1 basis point error difference
        assertApproxEqAbs((10_000 * sirRewards) / (3 * YEAR_ISSUANCE), 536, 1);
    }
}

interface ITreasuryV1 {
    function relayCall(address to, bytes memory data) external returns (bytes memory);
}

contract TreasuryTest is Test {
    address constant OWNER = 0x5000Ff6Cc1864690d947B864B9FB0d603E8d1F1A;
    address constant TREASURY = 0x686748764c5C7Aa06FEc784E60D14b650bF79129;

    address payable sir;

    function setUp() public {
        vm.createSelectFork("mainnet", 21873556);

        // Deploy oracle
        address oracle = address(new Oracle(Addresses.ADDR_UNISWAPV3_FACTORY));

        // Deploy SystemControl
        address systemControl = address(new SystemControl());

        // Deploy Contributors
        address contributors = address(new Contributors());

        // Deploy SIR
        sir = payable(address(new SIR(contributors, Addresses.ADDR_WETH, systemControl)));

        // Deploy APE implementation
        address apeImplementation = address(new APE());

        // Deploy Vault
        address vault = address(new Vault(systemControl, sir, oracle, apeImplementation, Addresses.ADDR_WETH));

        // Initialize SIR
        SIR(sir).initialize(vault);

        // Initialize SystemControl
        SystemControl(systemControl).initialize(vault, sir);
    }

    function test_treasuryMintsSIR() public {
        skip(1000 days);

        assertEq(IERC20(sir).balanceOf(TREASURY), 0);
        vm.prank(OWNER);
        ITreasuryV1(TREASURY).relayCall(sir, abi.encodeWithSelector(SIR.contributorMint.selector));
        assertTrue(IERC20(sir).balanceOf(TREASURY) > 0);
    }

    function test_noBodyMintsSIR() public {
        skip(1000 days);

        assertEq(IERC20(sir).balanceOf(TREASURY), 0);
        vm.expectRevert();
        ITreasuryV1(TREASURY).relayCall(sir, abi.encodeWithSelector(SIR.contributorMint.selector));
    }
}
