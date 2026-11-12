// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.29;

/// @title Mock USDC (demo token only)
/// @notice A plain ERC20 with 6 decimals, like real USDC, but it is a
/// demo token with NO real value: it only exists so the demo can show
/// funds visibly changing from ETH into a dollar token. Only the
/// designated minter (the MockSwap contract) can mint it. The owner can
/// move the minter role if the swap is ever redeployed.
contract MockUSDC {
    string public name = "Mock USDC";
    string public symbol = "mUSDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;

    address public owner;
    address public minter;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event MinterSet(address indexed minter);

    error NotOwner();
    error NotMinter();
    error ZeroAddress();
    error InsufficientBalance();
    error InsufficientAllowance();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyMinter() {
        if (msg.sender != minter) revert NotMinter();
        _;
    }

    constructor(address minter_) {
        if (minter_ == address(0)) revert ZeroAddress();
        owner = msg.sender;
        minter = minter_;
    }

    function setMinter(address minter_) external onlyOwner {
        if (minter_ == address(0)) revert ZeroAddress();
        minter = minter_;
        emit MinterSet(minter_);
    }

    function mint(address to_, uint256 amount_) external onlyMinter {
        if (to_ == address(0)) revert ZeroAddress();
        totalSupply += amount_;
        balanceOf[to_] += amount_;
        emit Transfer(address(0), to_, amount_);
    }

    function transfer(address to_, uint256 amount_) external returns (bool) {
        _transfer(msg.sender, to_, amount_);
        return true;
    }

    function approve(address spender_, uint256 amount_) external returns (bool) {
        allowance[msg.sender][spender_] = amount_;
        emit Approval(msg.sender, spender_, amount_);
        return true;
    }

    function transferFrom(address from_, address to_, uint256 amount_) external returns (bool) {
        uint256 allowed = allowance[from_][msg.sender];
        if (allowed < amount_) revert InsufficientAllowance();
        allowance[from_][msg.sender] = allowed - amount_;
        _transfer(from_, to_, amount_);
        return true;
    }

    function _transfer(address from_, address to_, uint256 amount_) internal {
        if (to_ == address(0)) revert ZeroAddress();
        if (balanceOf[from_] < amount_) revert InsufficientBalance();
        balanceOf[from_] -= amount_;
        balanceOf[to_] += amount_;
        emit Transfer(from_, to_, amount_);
    }
}
