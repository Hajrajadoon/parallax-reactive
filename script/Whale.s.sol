// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console2 } from "forge-std/Script.sol";
import { ParallaxToken } from "../src/amm/ParallaxToken.sol";
import { ParallaxPair } from "../src/amm/ParallaxPair.sol";

/// @notice Demo helper: a "whale" knocks one pool out of line so Parallax has something to arbitrage.
/// @dev    SIDE=UNI|BASE  DIRECTION=dump|pump  AMOUNT=<wei>
///         dump = sell AMOUNT of pWETH (price drops)   pump = spend AMOUNT of pUSD on pWETH (price rises)
contract Whale is Script {
    function run() external {
        string memory side = vm.envString("SIDE");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        ParallaxPair pool = ParallaxPair(vm.envAddress(string.concat(side, "_POOL")));
        ParallaxToken base = ParallaxToken(vm.envAddress(string.concat(side, "_BASE_TOKEN")));
        ParallaxToken quote = ParallaxToken(vm.envAddress(string.concat(side, "_QUOTE_TOKEN")));
        bool dump = keccak256(bytes(vm.envOr("DIRECTION", string("dump")))) == keccak256("dump");
        uint256 amount = vm.envOr("AMOUNT", uint256(8 ether));
        address me = vm.addr(pk);

        ParallaxToken tokenIn = dump ? base : quote;

        vm.startBroadcast(pk);
        tokenIn.mint(me, amount);
        tokenIn.approve(address(pool), amount);
        uint256 out = pool.swapExactIn(address(tokenIn), amount, 0, me);
        vm.stopBroadcast();

        (uint112 r0, uint112 r1,) = pool.getReserves();
        string memory label = dump ? string("WHALE DUMP on") : string("WHALE PUMP on");
        console2.log(label, side);
        console2.log("amount in  (wei)", amount);
        console2.log("amount out (wei)", out);
        console2.log("new price  (pUSD per pWETH, 1e18)", (uint256(r1) * 1e18) / uint256(r0));
    }
}
