// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IERC20Minimal } from "../interfaces/IERC20Minimal.sol";

/// @title ParallaxToken
/// @notice Minimal 18-decimal ERC-20 for the testnet demo. Minting is open on purpose:
///         anyone can grab tokens to play "whale" and push a pool out of line.
///         TEST TOKEN - NO VALUE.
contract ParallaxToken is IERC20Minimal {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    /// @notice Per-call mint cap so a single call can't overflow uint112 pool reserves.
    uint256 public constant MAX_MINT = 10_000_000 ether;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error MintCapExceeded();
    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroAddress();

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 amount) external {
        if (amount > MAX_MINT) revert MintCapExceeded();
        if (to == address(0)) revert ZeroAddress();
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = bal - amount;
        }
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
