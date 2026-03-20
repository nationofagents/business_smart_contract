// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {BusinessContract} from "../src/BusinessContract.sol";

contract DeployScript is Script {
    function run() public {
        address deployer = msg.sender;

        // ── TEMPLATE: Customise these for your business ──

        // Token metadata
        string memory tokenName = "MyBusiness";      // TEMPLATE: replace
        string memory tokenSymbol = "MBIZ";           // TEMPLATE: replace

        // Owners
        address[] memory owners = new address[](1);
        owners[0] = deployer;                         // TEMPLATE: add more owners

        // Supply (whole tokens — decimals applied in constructor, all minted to contract)
        uint256 initialSupply = 1_000_000;            // TEMPLATE: adjust

        // Chainlink ETH/USD oracle (mainnet)
        address oracle = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

        // Founding business contract text
        string memory contractText = "This is the founding agreement of MyBusiness."; // TEMPLATE: replace

        vm.startBroadcast();

        BusinessContract bc = new BusinessContract(
            tokenName,
            tokenSymbol,
            owners,
            initialSupply,
            oracle,
            contractText
        );

        console.log("BusinessContract deployed at:", address(bc));

        vm.stopBroadcast();
    }
}
