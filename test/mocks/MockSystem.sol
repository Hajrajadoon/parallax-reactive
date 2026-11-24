// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Stand-in for the Reactive system contract (0x8888...8888) in unit tests.
///         Its runtime code is etched at the system address; it records subscriptions and callback requests
///         so tests can replay them against the executors exactly as Reactive Network would.
contract MockSystem {
    struct Sub {
        uint256 chainId;
        address contractAddress;
        uint256 topic0;
    }

    struct Cb {
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    Sub[] internal _subs;
    Cb[] internal _cbs;

    function subscribe(uint256 chainId_, address contract_, uint256 topic0_, uint256, uint256, uint256) external {
        _subs.push(Sub(chainId_, contract_, topic0_));
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external { }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        _cbs.push(Cb(config_.chainId, config_.recipient, config_.gasLimit, config_.payload));
    }

    function subscriptionCount() external view returns (uint256) {
        return _subs.length;
    }

    function subscriptionAt(uint256 i) external view returns (uint256, address, uint256) {
        Sub storage s = _subs[i];
        return (s.chainId, s.contractAddress, s.topic0);
    }

    function callbackCount() external view returns (uint256) {
        return _cbs.length;
    }

    function callbackAt(uint256 i) external view returns (uint256, address, uint64, bytes memory) {
        Cb storage c = _cbs[i];
        return (c.chainId, c.recipient, c.gasLimit, c.payload);
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable { }
}
