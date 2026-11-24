// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console2 } from "forge-std/Script.sol";
import { ParallaxToken } from "../src/amm/ParallaxToken.sol";
import { ParallaxPair } from "../src/amm/ParallaxPair.sol";

/// @notice Deploys pWETH + pUSD + a seeded ParallaxPair on one origin chain.
/// @dev    SIDE=UNI|BASE  PRIVATE_KEY=0x...  forge script script/DeployOrigin.s.sol --rpc-url <rpc> --broadcast
///         Writes deployments/<SIDE>.origin.env
contract DeployOrigin is Script {
    function run() external {
        string memory side = vm.envString("SIDE");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        uint256 liqBase = vm.envOr("LIQ_BASE", uint256(100 ether));
        uint256 liqQuote = vm.envOr("LIQ_QUOTE", uint256(300_000 ether));
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        ParallaxToken base = new ParallaxToken("Parallax Wrapped Ether", "pWETH");
        ParallaxToken quote = new ParallaxToken("Parallax USD", "pUSD");
        // token0 = base, token1 = quote  -> baseIsToken0 = true for the reactive contract
        ParallaxPair pair = new ParallaxPair(address(base), address(quote));
        base.mint(deployer, liqBase);
        quote.mint(deployer, liqQuote);
        base.approve(address(pair), liqBase);
        quote.approve(address(pair), liqQuote);
        pair.addLiquidity(liqBase, liqQuote);
        vm.stopBroadcast();

        string memory out = string.concat(
            "export ", side, "_BASE_TOKEN=", vm.toString(address(base)), "\n",
            "export ", side, "_QUOTE_TOKEN=", vm.toString(address(quote)), "\n",
            "export ", side, "_POOL=", vm.toString(address(pair)), "\n"
        );
        vm.writeFile(string.concat("deployments/", side, ".origin.env"), out);

        console2.log("side      ", side);
        console2.log("pWETH     ", address(base));
        console2.log("pUSD      ", address(quote));
        console2.log("pool      ", address(pair));
    }
}
