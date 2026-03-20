// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @notice Minimal Chainlink aggregator interface for price feeds.
interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

/// @title Business Contract (Template)
/// @notice Non-upgradeable ERC-20 with multi-owner governance, USD-priced market,
///         and a signed-by-all-owners business contract text field.
///         All tokens are minted to the contract at deployment. Owners open a market
///         to sell tokens at a USD-denominated valuation, priced via Chainlink ETH/USD.
contract BusinessContract is ERC20, ERC20Permit, ERC20Votes {

    // ── Identity ──────────────────────────────────────
    bytes32 public constant NOA_IDENTIFIER = keccak256("nation-of-agents-business-v1");

    // ── Constants ─────────────────────────────────────
    uint256 public constant PCT_BASE = 1_000_000;       // 10^6 = 100%
    uint256 public constant ORACLE_STALENESS = 3600;     // 1 hour max

    // ── Business owners ───────────────────────────────
    address[] public business_owners;
    mapping(address => bool) public isBusinessOwner;

    // ── Market ────────────────────────────────────────
    AggregatorV3Interface public immutable ethUsdOracle;
    uint256 public market_sell_pct;       // 0 to PCT_BASE
    uint256 public market_valuation_usd;  // whole USD (e.g. 10_000_000 = $10M)
    uint256 public market_sold;           // tokens sold in current round (smallest unit)

    // ── Business contract text ────────────────────────
    string public business_contract_text;
    bytes32 public business_contract_hash;

    // ── Events ────────────────────────────────────────
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

    /// @param tokenName           e.g. "Acme Corp Token"
    /// @param tokenSymbol         e.g. "ACME"
    /// @param initialOwners       Addresses that form the initial owner set
    /// @param initialSupply       Whole tokens minted to the contract treasury (decimals applied)
    /// @param oracle              Chainlink ETH/USD price feed address
    /// @param initialContractText The founding business agreement
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
            address owner = initialOwners[i];
            require(owner != address(0), "Zero address owner");
            require(!isBusinessOwner[owner], "Duplicate owner");
            business_owners.push(owner);
            isBusinessOwner[owner] = true;
            emit OwnerAdded(owner);
        }

        ethUsdOracle = AggregatorV3Interface(oracle);
        business_contract_text = initialContractText;
        business_contract_hash = keccak256(bytes(initialContractText));

        // All tokens go to the contract itself
        _mint(address(this), initialSupply * 10 ** decimals());

        emit NOABusinessCreated(address(this), msg.sender);
    }

    // ──────────────────────────────────────────────
    //  Minting (any business owner)
    // ──────────────────────────────────────────────

    function mint(address to, uint256 amount) public onlyBusinessOwner {
        _mint(to, amount);
    }

    // ──────────────────────────────────────────────
    //  Market: USD-priced token sales from treasury
    // ──────────────────────────────────────────────

    /// @notice Open (or update) the market. Resets sold counter.
    /// @param sellPct      Fraction of total supply to offer (0..PCT_BASE, where PCT_BASE = 100%)
    /// @param valuationUsd Total business valuation in whole USD (e.g. 10_000_000 = $10M)
    function open_market(uint256 sellPct, uint256 valuationUsd) external onlyBusinessOwner {
        require(sellPct > 0 && sellPct <= PCT_BASE, "sellPct out of range");
        require(valuationUsd > 0, "Valuation must be > 0");

        market_sell_pct = sellPct;
        market_valuation_usd = valuationUsd;
        market_sold = 0;

        emit MarketOpened(sellPct, valuationUsd);
    }

    /// @notice Close the market. No more purchases until open_market is called again.
    function close_market() external onlyBusinessOwner {
        market_sell_pct = 0;
        emit MarketClosed();
    }

    /// @notice Buy tokens from the contract treasury. Sends ETH, receives tokens
    ///         priced at the current Chainlink ETH/USD rate against the set valuation.
    /// @param minTokensOut Minimum tokens (smallest unit) the buyer will accept (slippage protection)
    function buy_token(uint256 minTokensOut) external payable {
        require(market_sell_pct > 0, "Market not open");
        require(msg.value > 0, "No ETH sent");

        uint256 ethUsdPrice = _getEthUsdPrice(); // 8 decimals

        // tokens = msg.value * ethUsdPrice * totalSupply() / (10^8 * valuation_usd * 10^decimals())
        // Simplified (totalSupply already includes decimals):
        // tokens = msg.value * ethUsdPrice * totalSupply() / (10^8 * valuation_usd * 10^18)
        //
        // But totalSupply() = initialSupply * 10^18, so:
        // tokens = msg.value * ethUsdPrice * initialSupply * 10^18 / (10^8 * valuation_usd * 10^18)
        //        = msg.value * ethUsdPrice * initialSupply / (10^8 * valuation_usd)
        //
        // More precisely, using totalSupply() directly:
        uint256 tokens = (msg.value * ethUsdPrice * totalSupply()) / (1e8 * market_valuation_usd * 1e18);

        require(tokens > 0, "ETH amount too small");
        require(tokens >= minTokensOut, "Slippage: tokens below minimum");

        // Check against round allocation
        uint256 maxForSale = (totalSupply() * market_sell_pct) / PCT_BASE;
        require(market_sold + tokens <= maxForSale, "Exceeds market allocation");

        // Check contract actually holds enough
        require(balanceOf(address(this)) >= tokens, "Insufficient treasury balance");

        market_sold += tokens;
        _transfer(address(this), msg.sender, tokens);

        emit TokensPurchased(msg.sender, tokens, msg.value);
    }

    /// @notice View: how many tokens remain for sale in the current round.
    function market_remaining() external view returns (uint256) {
        if (market_sell_pct == 0) return 0;
        uint256 maxForSale = (totalSupply() * market_sell_pct) / PCT_BASE;
        if (market_sold >= maxForSale) return 0;
        uint256 remaining = maxForSale - market_sold;
        uint256 treasury = balanceOf(address(this));
        return remaining < treasury ? remaining : treasury;
    }

    /// @notice View: price per whole token in ETH at current oracle rate.
    function token_price_eth() external view returns (uint256) {
        uint256 ethUsdPrice = _getEthUsdPrice();
        // price_usd_per_token = valuation / (totalSupply / 10^18)
        // price_eth = price_usd_per_token / (ethUsdPrice / 10^8)
        //           = valuation * 10^8 * 10^18 / (totalSupply * ethUsdPrice)
        if (totalSupply() == 0 || ethUsdPrice == 0 || market_valuation_usd == 0) return 0;
        return (market_valuation_usd * 1e8 * 1e18) / (totalSupply() * ethUsdPrice / 1e18);
    }

    function _getEthUsdPrice() internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = ethUsdOracle.latestRoundData();
        require(answer > 0, "Invalid oracle price");
        require(block.timestamp - updatedAt <= ORACLE_STALENESS, "Stale oracle price");
        return uint256(answer); // 8 decimals
    }

    // ──────────────────────────────────────────────
    //  Owner management (requires ALL owner signatures)
    // ──────────────────────────────────────────────

    /// @notice Add a new owner. Requires a valid personal_sign from every current owner.
    ///         Each owner signs: keccak256("add owner ", <newOwner>)
    function addOwner(address newOwner, bytes[] calldata signatures) external {
        require(newOwner != address(0), "Zero address");
        require(!isBusinessOwner[newOwner], "Already an owner");

        bytes32 messageHash = keccak256(abi.encodePacked("add owner ", newOwner));
        _requireAllOwnerSignatures(messageHash, signatures);

        business_owners.push(newOwner);
        isBusinessOwner[newOwner] = true;
        emit OwnerAdded(newOwner);
    }

    /// @notice Remove an owner. Requires a valid personal_sign from every current owner.
    ///         Each owner signs: keccak256("remove owner ", <owner>)
    function removeOwner(address owner, bytes[] calldata signatures) external {
        require(isBusinessOwner[owner], "Not an owner");
        require(business_owners.length > 1, "Cannot remove last owner");

        bytes32 messageHash = keccak256(abi.encodePacked("remove owner ", owner));
        _requireAllOwnerSignatures(messageHash, signatures);

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

    function getBusinessOwnerCount() public view returns (uint256) {
        return business_owners.length;
    }

    // ──────────────────────────────────────────────
    //  Signature verification (shared by all multi-sig operations)
    // ──────────────────────────────────────────────

    /// @dev Verifies that every current business owner has signed the given message hash.
    function _requireAllOwnerSignatures(bytes32 messageHash, bytes[] calldata signatures) internal view {
        require(signatures.length == business_owners.length, "Need all owner signatures");

        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        bool[] memory signed = new bool[](business_owners.length);

        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = ECDSA.recover(ethSignedMessageHash, signatures[i]);
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

    // ──────────────────────────────────────────────
    //  Business contract text (requires ALL owner signatures)
    // ──────────────────────────────────────────────

    /// @notice Update the business contract text. Requires a valid personal_sign
    ///         signature from every current business owner.
    ///
    ///         Each owner signs: keccak256("I agree to this update from ", <oldHash>, " to ", <newHash>)
    function updateBusinessContract(string calldata newText, bytes[] calldata signatures) external {
        bytes32 newHash = keccak256(bytes(newText));
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "I agree to this update from ",
                business_contract_hash,
                " to ",
                newHash
            )
        );
        _requireAllOwnerSignatures(messageHash, signatures);

        bytes32 oldHash = business_contract_hash;
        business_contract_text = newText;
        business_contract_hash = newHash;

        emit BusinessContractUpdated(oldHash, newHash);
    }

    /// @notice Helper: returns the digest owners must sign to approve a contract text update.
    function getUpdateDigest(string calldata newText) external view returns (bytes32) {
        bytes32 newHash = keccak256(bytes(newText));
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "I agree to this update from ",
                business_contract_hash,
                " to ",
                newHash
            )
        );
        return MessageHashUtils.toEthSignedMessageHash(messageHash);
    }

    /// @notice Helper: returns the digest owners must sign to add a new owner.
    function getAddOwnerDigest(address newOwner) external pure returns (bytes32) {
        return MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encodePacked("add owner ", newOwner))
        );
    }

    /// @notice Helper: returns the digest owners must sign to remove an owner.
    function getRemoveOwnerDigest(address owner) external pure returns (bytes32) {
        return MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encodePacked("remove owner ", owner))
        );
    }

    // ──────────────────────────────────────────────
    //  ETH management (any business owner)
    // ──────────────────────────────────────────────

    function withdrawEth(address payable to, uint256 amount) public onlyBusinessOwner {
        require(address(this).balance >= amount, "Insufficient ETH balance");
        (bool ok,) = to.call{value: amount}("");
        require(ok, "ETH transfer failed");
        emit EthWithdrawn(to, amount);
    }

    function withdrawAllEth(address payable to) public onlyBusinessOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
        (bool ok,) = to.call{value: balance}("");
        require(ok, "ETH transfer failed");
        emit EthWithdrawn(to, balance);
    }

    // ──────────────────────────────────────────────
    //  Votes / clock overrides (timestamp mode)
    // ──────────────────────────────────────────────

    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    // ──────────────────────────────────────────────
    //  Required overrides
    // ──────────────────────────────────────────────

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, value);
    }

    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}
