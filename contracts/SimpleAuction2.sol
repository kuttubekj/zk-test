// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;


import "./interfaces/IERC721.sol";
import "./interfaces/IERC20.sol";
// import "./Verifier.sol";
import "./libs/PoseidonT3.sol";
// import {console} from "forge-std/console.sol";

interface IVerifier {
    function verifyProof(uint[2] calldata _pA, uint[2][2] calldata _pB, uint[2] calldata _pC, uint[3] calldata _pubSignals) external view returns (bool);
}

contract SimpleAuction2 {

    IVerifier verifier;

    mapping(bytes32 => Order) public orders; 

    mapping(address => mapping(address => uint)) public balances;

    struct Order {
        address maker;          // 0x1234 owner of the order
        address baseToken;      // BAYC
        address quoteToken;     // ETH
        uint price;             // ETH/BAYC = 32.42 = #quoteToken per token
        uint baseTokenId;       // BAYC #12 - baseToken
        uint expiry;            // timestamp in seconds
        bool orderType;         // 0 = bid, 1 = ask
    }

    struct Bid {
        address bidder;          // 0x1234 owner of the order
        address baseToken;      // BAYC
        address quoteToken;     // ETH
        uint baseTokenId;       // BAYC #12 - baseToken
        uint hashedPrice;            // timestamp in seconds
        uint[2] pA;
        uint[2][2] pB;
        uint[2] pC;
        uint[3] pubSignals;
    }

    struct Trade {
        address taker;
        uint64 blockNumber;
        bytes32 orderHash;
    }
    Trade[] public trades;
    mapping(bytes32 => Bid) public bids;

    event OrderFilled(bytes32 orderHash, address taker, address maker, address baseToken, address quoteToken, uint price, uint baseTokenId, uint expiry, bool orderType);
    event BidExecuted(bytes32 orderHash, address taker, address maker, address baseToken, address quoteToken, uint price, uint baseTokenId);
    
    constructor(address _verifier) {
        verifier = IVerifier(_verifier);
    }

    /// @dev Get the trade from the trade list
    function getTrade(uint index) public view returns (address, uint64, bytes32) {
        Trade memory trade = trades[index];
        return (trade.taker, trade.blockNumber, trade.orderHash);
    }

    /// @dev Get the order from the orderbook
    function getOrder(bytes32 orderHash) public view returns (address, address, address, uint, uint, uint, bool) {
        Order memory order = orders[orderHash];
        return (order.maker, order.baseToken, order.quoteToken, order.price, order.baseTokenId, order.expiry, order.orderType);
    }

    /// @dev Add balance to the contract
    function addBalance(address _user, address _token, uint _amount) public {
        IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        balances[_token][_user] += _amount;
    }

    /// @dev Add order to the orderbook
    function addOrder(address _baseToken, address _quoteToken, uint256 _price, uint _baseTokenId, uint _expiry, bool _orderType) public returns ( bytes32 ) {
        require(balances[_quoteToken][msg.sender] >= _price, "Insufficient balance");
        Order memory order = Order(msg.sender, _baseToken, _quoteToken, _price, _baseTokenId, _expiry, _orderType);
        bytes32 orderHash = keccak256(abi.encodePacked(order.maker, order.baseToken, order.quoteToken, order.price, order.baseTokenId, order.expiry, order.orderType));
        orders[orderHash] = order;
        return(orderHash);
    }

    /// @dev Make a bid
    function makeBid(
        address _baseToken,
        address _quoteToken,
        uint _baseTokenId, 
        uint priceHash,
        uint[2] calldata _pA,
        uint[2][2] calldata _pB,
        uint[2] calldata _pC
        // uint[3] calldata pubSignals
    ) public returns ( bytes32 ) {
        uint[3] memory pubSignals = [priceHash, 1, balances[_quoteToken][msg.sender]];
        // uint[3] memory pubSignals = [priceHash, uint(1), 1000];
        bool validProof = verifier.verifyProof(_pA, _pB, _pC, pubSignals);
        require(validProof, 'Invalid proof');

        bytes32 bidHash = keccak256(abi.encodePacked(_quoteToken, msg.sender, _pA, _pB, _pC, pubSignals));
        // console.logBytes32(bidHash);

        Bid memory bid = Bid(msg.sender, _baseToken, _quoteToken,  _baseTokenId, priceHash, _pA, _pB, _pC, pubSignals);
        bids[bidHash] = bid;
        return(bidHash);
    }

    /// @dev Add order to the orderbook with orderHash
    function addOrderHash(bytes32 orderHash) public {
        orders[orderHash] = Order(address(this), address(0), address(0), 0, 0, 0, false);
    }

    function updateOrderHash(bytes32 orderHash, uint[2] calldata _pA, uint[2][2] calldata _pB, uint[2] calldata _pC, uint[3] calldata _pubSignals) public returns (bool) {
        require(verifier.verifyProof(_pA, _pB, _pC, _pubSignals));
        orders[orderHash] = Order(address(this), address(0), address(0), _pubSignals[0], 0, 0, false);
        return true;
    }
  
    /// @dev Taker execute orders.
    /// @param orderHash OrderIndex for order
    function executeOrder (
        bytes32 orderHash
    ) external payable {
        Order memory order = orders[orderHash];
        require(order.maker != address(0), "Order does not exist");
        require(order.expiry > block.timestamp, "Order expired");
        require(balances[order.quoteToken][order.maker] > order.price, "Order expired");

        trades.push(Trade(msg.sender, uint64(block.number), orderHash));
        balances[order.quoteToken][order.maker] -= order.price;
        // Remove the order from the orderbook
        delete orders[orderHash];

        // Transfer the token from the maker to the taker
        IERC721(order.baseToken).transferFrom(address(this), msg.sender, order.baseTokenId);
        
        // Transfer the quoteToken from the taker to the maker
        IERC20(order.quoteToken).transferFrom(msg.sender, order.maker, order.price);

        // Emit the event
        emit OrderFilled(orderHash, msg.sender, order.maker, order.baseToken, order.quoteToken, order.price, order.baseTokenId, order.expiry, order.orderType);
    }
  
    /// @dev Taker execute orders.
    /// @param bidHash OrderIndex for order
    function endAuction (
        bytes32 bidHash,
        uint256 price
    ) external payable {
        Bid memory bid = bids[bidHash];
        uint256[2] memory elementsToHash = [price, bid.pubSignals[0]];
        require(bid.bidder != address(0), "Bid does not exist");
        require(balances[bid.quoteToken][bid.bidder] > price, "Insufficient balance");
        require(PoseidonT3.hash(elementsToHash) == bid.hashedPrice, "Incorrect price");

        balances[bid.quoteToken][bid.bidder] -= price;
        // Remove the bid from the bids
        delete bids[bidHash];

        // Transfer the token from the maker to the taker
        IERC721(bid.baseToken).transferFrom(address(this), msg.sender, bid.baseTokenId);
        
        // Transfer the quoteToken from the taker to the maker
        IERC20(bid.quoteToken).transferFrom(msg.sender, bid.bidder, price);

        // Emit the event
        emit BidExecuted(bidHash, msg.sender, bid.bidder, bid.baseToken, bid.quoteToken, price, bid.baseTokenId);
    }
    
}
