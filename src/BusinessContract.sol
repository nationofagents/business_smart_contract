// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80, int256, uint256, uint256, uint80
    );
}

contract BusinessContract is ERC20, ERC20Permit, ERC20Votes {

    bytes32 public constant NOA_IDENTIFIER = keccak256("nation-of-agents-business-v1");
    uint256 public constant PCT_BASE = 1_000_000;
    uint256 public constant ORACLE_STALENESS = 3600;

    address[] public business_owners;
    mapping(address => bool) public isBusinessOwner;

    AggregatorV3Interface public immutable ethUsdOracle;
    uint256 public market_sell_pct;
    uint256 public market_valuation_usd;
    uint256 public market_sold;

    string public business_contract_text;
    bytes32 public business_contract_hash;

    event NOABusinessCreated(address indexed contractAddress, address indexed creator);
    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);
    event MarketOpened(uint256 sellPct, uint256 valuationUsd);
    event MarketClosed();
    event TokensPurchased(address indexed buyer, uint256 tokens, uint256 ethPaid);
    event BusinessContractUpdated(bytes32 oldHash, bytes32 newHash);
    event EthWithdrawn(address indexed to, uint256 amount);

    modifier onlyBusinessOwner() {
        require(isBusinessOwner[msg.sender], "Not a business owner");
        _;
    }

    constructor(
        string memory tokenName,
        string memory tokenSymbol,
        address[] memory initialOwners,
        uint256 initialSupply,
        address oracle,
        string memory initialContractText
    ) ERC20(tokenName, tokenSymbol) ERC20Permit(tokenName) {
        require(initialOwners.length > 0, "Need at least one owner");
        require(oracle != address(0), "Zero oracle address");

        for (uint256 i = 0; i < initialOwners.length; i++) {
            address o = initialOwners[i];
            require(o != address(0), "Zero address owner");
            require(!isBusinessOwner[o], "Duplicate owner");
            business_owners.push(o);
            isBusinessOwner[o] = true;
            emit OwnerAdded(o);
        }

        ethUsdOracle = AggregatorV3Interface(oracle);
        business_contract_text = initialContractText;
        business_contract_hash = keccak256(bytes(initialContractText));
        _mint(address(this), initialSupply * 10 ** decimals());
        emit NOABusinessCreated(address(this), msg.sender);
    }

    function mint(address to, uint256 amount) external onlyBusinessOwner {
        _mint(to, amount);
    }

    function open_market(uint256 sellPct, uint256 valuationUsd) external onlyBusinessOwner {
        require(sellPct > 0 && sellPct <= PCT_BASE, "sellPct out of range");
        require(valuationUsd > 0, "Valuation must be > 0");
        market_sell_pct = sellPct;
        market_valuation_usd = valuationUsd;
        market_sold = 0;
        emit MarketOpened(sellPct, valuationUsd);
    }

    function close_market() external onlyBusinessOwner {
        market_sell_pct = 0;
        emit MarketClosed();
    }

    function buy_token(uint256 minTokensOut) external payable {
        require(market_sell_pct > 0, "Market not open");
        require(msg.value > 0, "No ETH sent");

        uint256 ethUsdPrice = _getEthUsdPrice();
        uint256 tokens = (msg.value * ethUsdPrice * totalSupply()) / (1e8 * market_valuation_usd * 1e18);

        require(tokens > 0, "ETH amount too small");
        require(tokens >= minTokensOut, "Slippage: tokens below minimum");

        uint256 maxForSale = (totalSupply() * market_sell_pct) / PCT_BASE;
        require(market_sold + tokens <= maxForSale, "Exceeds market allocation");
        require(balanceOf(address(this)) >= tokens, "Insufficient treasury");

        market_sold += tokens;
        _transfer(address(this), msg.sender, tokens);
        emit TokensPurchased(msg.sender, tokens, msg.value);
    }

    function market_remaining() external view returns (uint256) {
        if (market_sell_pct == 0) return 0;
        uint256 maxForSale = (totalSupply() * market_sell_pct) / PCT_BASE;
        if (market_sold >= maxForSale) return 0;
        uint256 remaining = maxForSale - market_sold;
        uint256 treasury = balanceOf(address(this));
        return remaining < treasury ? remaining : treasury;
    }

    function token_price_eth() external view returns (uint256) {
        uint256 ethUsdPrice = _getEthUsdPrice();
        if (totalSupply() == 0 || ethUsdPrice == 0 || market_valuation_usd == 0) return 0;
        return (market_valuation_usd * 1e8 * 1e18) / (totalSupply() * ethUsdPrice / 1e18);
    }

    function _getEthUsdPrice() internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = ethUsdOracle.latestRoundData();
        require(answer > 0, "Invalid oracle price");
        require(block.timestamp - updatedAt <= ORACLE_STALENESS, "Stale oracle price");
        return uint256(answer);
    }

    function addOwner(address newOwner, bytes[] calldata signatures) external {
        require(newOwner != address(0), "Zero address");
        require(!isBusinessOwner[newOwner], "Already an owner");
        _requireAllOwnerSignatures(keccak256(abi.encodePacked("add owner ", newOwner)), signatures);
        business_owners.push(newOwner);
        isBusinessOwner[newOwner] = true;
        emit OwnerAdded(newOwner);
    }

    function removeOwner(address owner, bytes[] calldata signatures) external {
        require(isBusinessOwner[owner], "Not an owner");
        require(business_owners.length > 1, "Cannot remove last owner");
        _requireAllOwnerSignatures(keccak256(abi.encodePacked("remove owner ", owner)), signatures);
        isBusinessOwner[owner] = false;
        for (uint256 i = 0; i < business_owners.length; i++) {
            if (business_owners[i] == owner) {
                business_owners[i] = business_owners[business_owners.length - 1];
                business_owners.pop();
                break;
            }
        }
        emit OwnerRemoved(owner);
    }

    function getBusinessOwners() public view returns (address[] memory) {
        return business_owners;
    }

    function _requireAllOwnerSignatures(bytes32 messageHash, bytes[] calldata signatures) internal view {
        require(signatures.length == business_owners.length, "Need all owner signatures");
        bytes32 ethSigned = MessageHashUtils.toEthSignedMessageHash(messageHash);
        bool[] memory signed = new bool[](business_owners.length);
        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = ECDSA.recover(ethSigned, signatures[i]);
            bool found = false;
            for (uint256 j = 0; j < business_owners.length; j++) {
                if (business_owners[j] == signer && !signed[j]) {
                    signed[j] = true;
                    found = true;
                    break;
                }
            }
            require(found, "Invalid or duplicate signature");
        }
        for (uint256 i = 0; i < signed.length; i++) {
            require(signed[i], "Missing owner signature");
        }
    }

    function updateBusinessContract(string calldata newText, bytes[] calldata signatures) external {
        bytes32 newHash = keccak256(bytes(newText));
        _requireAllOwnerSignatures(
            keccak256(abi.encodePacked("I agree to this update from ", business_contract_hash, " to ", newHash)),
            signatures
        );
        bytes32 oldHash = business_contract_hash;
        business_contract_text = newText;
        business_contract_hash = newHash;
        emit BusinessContractUpdated(oldHash, newHash);
    }

    function getDigest(string calldata prefix, bytes memory payload) external view returns (bytes32) {
        bytes32 messageHash;
        if (keccak256(bytes(prefix)) == keccak256("update")) {
            bytes32 newHash = keccak256(payload);
            messageHash = keccak256(abi.encodePacked("I agree to this update from ", business_contract_hash, " to ", newHash));
        } else if (keccak256(bytes(prefix)) == keccak256("add owner")) {
            messageHash = keccak256(abi.encodePacked("add owner ", abi.decode(payload, (address))));
        } else if (keccak256(bytes(prefix)) == keccak256("remove owner")) {
            messageHash = keccak256(abi.encodePacked("remove owner ", abi.decode(payload, (address))));
        } else {
            revert("Unknown operation");
        }
        return MessageHashUtils.toEthSignedMessageHash(messageHash);
    }

    function withdrawEth(address payable to, uint256 amount) external onlyBusinessOwner {
        require(address(this).balance >= amount, "Insufficient ETH");
        (bool ok,) = to.call{value: amount}("");
        require(ok, "ETH transfer failed");
        emit EthWithdrawn(to, amount);
    }

    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
