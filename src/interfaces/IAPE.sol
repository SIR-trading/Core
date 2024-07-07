// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

interface IAPE {
    struct Fees {
        uint144 collateralInOrWithdrawn;
        uint144 collateralFeeToStakers;
        uint144 collateralFeeToGentlemen;
        uint144 collateralFeeToProtocol;
    }

    struct Reserves {
        uint144 reserveApes;
        uint144 reserveLPers;
        int64 tickPriceX42;
    }

    error InvalidSigner();
    error PermitDeadlineExpired();

    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function DOMAIN_SEPARATOR() external view returns (bytes32);

    function OWNER() external view returns (address);

    function allowance(address, address) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function balanceOf(address) external view returns (uint256);

    function burn(
        address from,
        uint16 baseFee,
        uint8 tax,
        Reserves memory reserves,
        uint256 amount
    ) external returns (Reserves memory newReserves, Fees memory fees);

    function collateralToken() external view returns (address);

    function debtToken() external view returns (address);

    function decimals() external view returns (uint8);

    function leverageTier() external view returns (int8);

    function mint(
        address to,
        uint16 baseFee,
        uint8 tax,
        Reserves memory reserves,
        uint144 collateralDeposited
    ) external returns (Reserves memory newReserves, Fees memory fees, uint256 amount);

    function name() external view returns (string memory);

    function nonces(address) external view returns (uint256);

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function symbol() external view returns (string memory);

    function totalSupply() external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
