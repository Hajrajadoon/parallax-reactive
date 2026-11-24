// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console2 } from "forge-std/Script.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { ParallaxExecutor } from "../src/ParallaxExecutor.sol";
import { ParallaxToken } from "../src/amm/ParallaxToken.sol";

/// @notice Deploys the callback executor on one destination chain, funds it with native gas for callbacks and
///         mints its trading inventory.
/// @dev    SIDE=UNI|BASE, needs <SIDE>_POOL, <SIDE>_BASE_TOKEN, <SIDE>_QUOTE_TOKEN, <SIDE>_CALLBACK_PROXY, REACTIVE_ADDR.
///         Writes deployments/<SIDE>.executor.env
contract DeployExecutor is Script {
    function run() external {
        string memory side = vm.envString("SIDE");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address proxy = vm.envAddress(string.concat(side, "_CALLBACK_PROXY"));
        address pool = vm.envAddress(string.concat(side, "_POOL"));
        address base = vm.envAddress(string.concat(side, "_BASE_TOKEN"));
        address quote = vm.envAddress(string.concat(side, "_QUOTE_TOKEN"));
        address reactive = vm.envAddress("REACTIVE_ADDR");
        uint256 gasFund = vm.envOr("EXECUTOR_GAS_FUND", uint256(0.02 ether));
        uint256 cooldown = vm.envOr("EXECUTOR_COOLDOWN", uint256(2));
        uint256 invBase = vm.envOr("INVENTORY_BASE", uint256(50 ether));
        uint256 invQuote = vm.envOr("INVENTORY_QUOTE", uint256(150_000 ether));

        vm.startBroadcast(pk);
        ParallaxExecutor executor = new ParallaxExecutor{ value: gasFund }(
            IPayable(payable(proxy)), reactive, pool, base, quote, cooldown
        );
        ParallaxToken(base).mint(address(executor), invBase);
        ParallaxToken(quote).mint(address(executor), invQuote);
        vm.stopBroadcast();

        vm.writeFile(
            string.concat("deployments/", side, ".executor.env"),
            string.concat("export ", side, "_EXECUTOR=", vm.toString(address(executor)), "\n")
        );

        console2.log("side      ", side);
        console2.log("executor  ", address(executor));
        console2.log("authorised reactive", reactive);
    }
}
