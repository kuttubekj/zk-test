// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;


import "./interfaces/IERC721.sol";
import "./interfaces/IERC20.sol";
import "./Verifier.sol";

contract SimpleAuction is Groth16Verifier {

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

    struct Trade {
        address taker;
        uint64 blockNumber;
        bytes32 orderHash;
    }
    Trade[] public trades;

    event OrderFilled(bytes32 orderHash, address taker, address maker, address baseToken, address quoteToken, uint price, uint baseTokenId, uint expiry, bool orderType);
    

    constructor() {
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

    /// @dev Add order to the orderbook with orderHash
    function addOrderHash(bytes32 orderHash) public {
        orders[orderHash] = Order(address(this), address(0), address(0), 0, 0, 0, false);
    }

    function updateOrderHash(bytes32 orderHash, uint[2] calldata _pA, uint[2][2] calldata _pB, uint[2] calldata _pC, uint[3] calldata _pubSignals) public returns (bool) {
        require(verifyProof(_pA, _pB, _pC, _pubSignals));
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


}


