// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";

/// @title DutchAuctionHouse
contract DutchAuctionHouse {
    event SellID(uint orderId);
    event BuyID(uint orderId);

    enum Modes {
        DepositWithdrawl,
        Offer,
        BidOpening,
        Matching
    }

    enum OP {
        Buy,
        Sell,
        Account,
        Global
    }

    struct Account {
        uint balance; // total ETH held
        uint debtAccrued; // total amount of possible debt owing
        mapping(address => uint) tokens; // owned tokens
        bool exists; // flag for existence
    }

    // Buy Orders exist on the buySideExchange.
    struct SellOrder {
        uint id;
        address owner;
        uint price;
        address token;
        uint amount;
        bool exists;
        // traversal variables
        uint previous;
        uint next;
    }

    enum OrderStatus {
        Closed,
        Open,
        Genesis
    }

    // A Buy Order can be a blind bid or an open bid.
    // Buy Orders exist on the buySideExchange.
    struct BuyOrder {
        uint id;
        address owner;
        bytes32 blindBid;
        OrderStatus status;
        bool exists;
        // open bid state variables
        address token;
        uint price;
        uint amount;
        // traversal variables
        uint previous;
        uint next;
    }

    // Mode consts
    uint private constant DURATION = 5 minutes;
    uint private constant N_MODES = 4;

    // Util consts
    address private constant NONE_ADDR = address(0x0);
    bytes32 private constant NONE_BID = bytes32(0x0);
    uint private constant NONE = 0;
    uint private constant GENESIS = 0;

    uint private immutable creationTime;
    Modes private mode = Modes.DepositWithdrawl;

    // User Accounts brokering ETH and tokens deposits
    mapping(address => Account) userAccounts;
    // Exchange tracking sell orders of a particular token type
    mapping(address => mapping(uint => SellOrder)) sellSideExchange;
    // Exchange tracking buy orders
    mapping(uint => BuyOrder) buySideExchange;
    // Index mapping ids to token types
    mapping(uint => address) sellSideIndex;

    // Dynamic order ids
    uint private buyOrderId = 1;
    uint private sellOrderId = 0;

    // Exchange locks
    bool private buyLock = false;
    bool private sellLock = false;
    bool private accountLock = false;

    constructor() {
        // initialise creation time
        creationTime = block.timestamp;
    }

    modifier during(Modes _mode) {
        poll_mode();
        // require(mode == _mode, "Action not allowed during this mode.");
        _;
    }

    modifier require_unique(address _account) {
        require(
            !userAccounts[_account].exists,
            "Account already exists. Action not allowed."
        );
        _;
    }

    modifier require_account(address _account) {
        require(
            userAccounts[_account].exists,
            "Account payable does not exist. Action not allowed."
        );
        _;
    }

    modifier require_token_ownership(address _account, address _tokenAddress) {
        require(
            userAccounts[_account].tokens[_tokenAddress] > 0,
            "User does not own token. Action not allowed."
        );
        _;
    }

    modifier require_order_ownership(
        OP _operation,
        address _account,
        uint _id
    ) {
        if (_operation == OP.Sell) {
            require(
                sellSideExchange[sellSideIndex[_id]][_id].owner == _account,
                "User has no sell order with corresponding id. Action not allowed."
            );
        } else {
            require(
                buySideExchange[_id].owner == _account,
                "User has no buy order with corresponding id. Action not allowed."
            );
        }

        _;
    }

    modifier require_mutex(OP _operation) {
        require(
            ((_operation == OP.Account && !accountLock) ||
                (_operation == OP.Sell && !sellLock)) ||
                (_operation == OP.Buy && !buyLock) ||
                (_operation == OP.Global && !(sellLock && buyLock)),
            "Cannot acquire lock. Operation failure."
        );
        _;
    }

    /// Creates an account.
    function create_account() public payable require_unique(msg.sender) {
        Account storage acc = userAccounts[msg.sender];
        acc.balance = 0;
        acc.exists = true;

        handle_deposit_funds(msg.sender, msg.value);
    }

    /// Creates an account, accepting a token.
    /// @param _tokenAddress the address of the token to be transfered
    /// @param _amount the amount of a particular token to transfer
    function create_token_account(
        address _tokenAddress,
        uint _amount
    ) public payable require_unique(msg.sender) {
        Account storage acc = userAccounts[msg.sender];
        acc.balance = 0;
        acc.exists = true;

        handle_deposit_funds(msg.sender, msg.value);
        handle_transfer_token(msg.sender, _tokenAddress, _amount, true);
    }

    /// Increases the amount of ETH available to a user who has an account.
    function deposit_funds()
        public
        payable
        during(Modes.DepositWithdrawl)
        require_account(msg.sender)
    {
        handle_deposit_funds(msg.sender, msg.value);
    }

    /// Returns funds to a user.
    /// @param transferTo the address for transfering the ETH
    /// @param _amount the amount of money to transfer out
    function withdraw_funds(
        address payable transferTo,
        uint _amount
    )
        public
        during(Modes.DepositWithdrawl)
        require_account(msg.sender)
        require_mutex(OP.Account)
    {
        acquire_lock(OP.Account);
        // Check user account balance is greater than requested amount.
        require(
            userAccounts[msg.sender].balance >= _amount,
            "Insufficient balance. Action not allowed."
        );

        uint withdrawAmount = userAccounts[msg.sender].balance;
        userAccounts[msg.sender].balance -= withdrawAmount;
        (bool success, ) = transferTo.call{value: withdrawAmount}("");

        if (!success) {
            userAccounts[msg.sender].balance += withdrawAmount;
            revert("Could not transfer ETH. Egress failure.");
        }
        release_lock(OP.Account);
    }

    /// Accepts a token for use in the Auction House.
    /// @param _tokenAddress the address of the token to be transfered
    /// @param _amount the amount of a particular token to transfer
    function deposit_token(
        address _tokenAddress,
        uint _amount
    ) public during(Modes.DepositWithdrawl) require_account(msg.sender) {
        handle_transfer_token(msg.sender, _tokenAddress, _amount, true);
    }

    /// Returns a token to a user.
    /// @param _tokenAddress the address of the token to be transferred
    /// @param _amount the amount of a particular token to transfer
    function withdraw_token(
        address _tokenAddress,
        uint _amount
    )
        public
        during(Modes.DepositWithdrawl)
        require_account(msg.sender)
        require_token_ownership(msg.sender, _tokenAddress)
        require_mutex(OP.Account)
    {
        acquire_lock(OP.Account);
        // Check user owns enough of the specified token.
        require(
            userAccounts[msg.sender].tokens[_tokenAddress] >= _amount,
            "User does not own enough of the specified token."
        );

        handle_transfer_token(msg.sender, _tokenAddress, _amount, false);
        release_lock(OP.Account);
    }

    /// Creates a sell order.
    /// @param _tokenAddress the address of the token to be transfered
    /// @param _amount the amount of a particular token to transfer
    /// @param _price the sell price
    function sell(
        address _tokenAddress,
        uint _amount,
        uint _price
    )
        public
        during(Modes.Offer)
        require_account(msg.sender)
        require_token_ownership(msg.sender, _tokenAddress)
        require_mutex(OP.Sell)
    {
        // Check user owns enough of the specified token.
        require(
            userAccounts[msg.sender].tokens[_tokenAddress] >= _amount,
            "User does not own enough of the specified token."
        );

        acquire_lock(OP.Sell);
        uint thisOrderId = seek_order_id(OP.Sell);
        sellSideIndex[thisOrderId] = _tokenAddress;

        // Navigate the Sell Exchange and place sell order in list order
        SellOrder memory currSell = sellSideExchange[_tokenAddress][
            sellOrderId
        ];

        while (currSell.id != NONE) {
            if (currSell.price <= _price) {
                break;
            }
            currSell = sellSideExchange[_tokenAddress][currSell.previous];
        }

        sellSideExchange[_tokenAddress][thisOrderId] = SellOrder(
            thisOrderId,
            msg.sender,
            _price,
            _tokenAddress,
            _amount,
            true,
            currSell.id,
            sellSideExchange[_tokenAddress][currSell.next].id
        );

        // update next node to point to curr
        sellSideExchange[_tokenAddress][currSell.next].previous = thisOrderId;
        // update prev node to point to curr
        sellSideExchange[_tokenAddress][currSell.id].next = thisOrderId;
        sellOrderId = thisOrderId;
        release_lock(OP.Sell);

        emit SellID(thisOrderId);
    }

    /// Removes an active sell order.
    /// @param _id the id of the order
    function withdraw_sell_order(
        uint _id
    )
        public
        during(Modes.Offer)
        require_account(msg.sender)
        require_order_ownership(OP.Sell, msg.sender, _id)
    {
        acquire_lock(OP.Sell);
        handle_remove_order(OP.Sell, _id);
        release_lock(OP.Sell);
    }

    /// Reduces the price of an active sell order.
    /// @param _id the id of the existing sell order
    /// @param _price the new sell price
    function reduce_price(
        uint _id,
        uint _price
    )
        public
        during(Modes.Offer)
        require_account(msg.sender)
        require_order_ownership(OP.Sell, msg.sender, _id)
        require_mutex(OP.Sell)
    {
        // Check tendered price is a reduction.
        require(
            sellSideExchange[sellSideIndex[_id]][_id].price > _price,
            "New price greater than current sell price"
        );

        acquire_lock(OP.Sell);
        sellSideExchange[sellSideIndex[_id]][_id].price = _price;
        release_lock(OP.Sell);
    }

    /// Creates a blind buy order.
    /// @param _bid a blind keccak256 hashed bid
    function buy(
        bytes32 _bid
    )
        public
        during(Modes.BidOpening)
        require_account(msg.sender)
        require_mutex(OP.Buy)
    {
        acquire_lock(OP.Buy);
        BuyOrder memory currBuy = buySideExchange[buyOrderId];
        uint thisOrderId = seek_order_id(OP.Buy);

        buySideExchange[thisOrderId] = BuyOrder(
            thisOrderId,
            msg.sender,
            _bid,
            OrderStatus.Closed,
            true,
            NONE_ADDR,
            0,
            0,
            currBuy.id,
            buySideExchange[currBuy.next].id
        );

        // update next node to point to curr
        buySideExchange[currBuy.next].previous = thisOrderId;
        // update prev node to point to curr
        buySideExchange[currBuy.id].next = thisOrderId;
        buyOrderId = thisOrderId;
        release_lock(OP.Buy);

        emit BuyID(thisOrderId);
    }

    /// Removes an active buy order from the market.
    /// @param _id the id of the buy order
    function withdraw_buy_order(
        uint _id
    )
        public
        during(Modes.BidOpening)
        require_account(msg.sender)
        require_mutex(OP.Buy)
        require_order_ownership(OP.Buy, msg.sender, _id)
    {
        userAccounts[msg.sender].debtAccrued -=
            buySideExchange[_id].amount *
            buySideExchange[_id].price;
        acquire_lock(OP.Buy);
        handle_remove_order(OP.Buy, _id);
        release_lock(OP.Buy);
    }

    function open_buy_order(
        uint _id,
        address _token,
        uint _price,
        uint _amount,
        uint _nonce
    )
        public
        during(Modes.BidOpening)
        require_account(msg.sender)
        require_mutex(OP.Buy)
        require_order_ownership(OP.Buy, msg.sender, _id)
    {
        // Check purported bid matches blind bid.
        bytes32 verifiedBid = keccak256(
            abi.encodePacked(_token, _price, _amount, _nonce)
        );

        require(
            verifiedBid == buySideExchange[_id].blindBid,
            "Buy order missmatch. Cannot open diverging bid."
        );

        // Check account has enough funds to meet open bid.
        require(
            _price * _amount <=
                userAccounts[msg.sender].balance -
                    userAccounts[msg.sender].debtAccrued,
            "User is unable to service this bid. Cannot open bid."
        );

        userAccounts[msg.sender].debtAccrued += _price * _amount;

        acquire_lock(OP.Buy);

        buySideExchange[_id].token = _token;
        buySideExchange[_id].price = _price;
        buySideExchange[_id].amount = _amount;
        buySideExchange[_id].status = OrderStatus.Open;

        release_lock(OP.Buy);
    }

    /// Begins the matching phase between market participants.
    function init_match_phase()
        public
        during(Modes.Matching)
        require_account(msg.sender)
        require_mutex(OP.Global)
    {
        acquire_lock(OP.Global);
        match_buy_sell_exchange();
        release_lock(OP.Global);
    }

    /// Determine the amount of time passed since the Auction genesis ...
    // ... in minutes.
    function poll_mode() internal {
        uint timeDiff = block.timestamp - creationTime / 60;
        uint modeDurationDiff = timeDiff % DURATION;
        uint modePivot = modeDurationDiff % N_MODES;

        // Check if the current mode is outdated.
        if (uint(mode) != modePivot) {
            assert(modePivot >= 0 && modePivot < 4);
            // The current mode is outdated, so update the mode.
            if (modePivot == 0) {
                mode = Modes.DepositWithdrawl;
            } else if (modePivot == 1) {
                mode = Modes.Offer;
            } else if (modePivot == 2) {
                mode = Modes.BidOpening;
            } else if (modePivot == 3) {
                mode = Modes.Matching;
            }
        }
    }

    /// Handles deposit of funds into the Auction House.
    function handle_deposit_funds(address _address, uint _amount) internal {
        userAccounts[_address].balance += _amount;
    }

    /// Transfer an ERC20 tojen from one address to another.
    /// This method handles both assuming and relieving ownership of a token.
    /// @param _publicParty the address of the foreign party
    /// @param _tokenAddress the address of the token type
    /// @param _amount the number of ERC20 tokens
    /// @param ingress whether ownership is being assumed
    function handle_transfer_token(
        address _publicParty,
        address _tokenAddress,
        uint _amount,
        bool ingress
    ) internal {
        bool success = false;
        if (ingress) {
            // transfer token into exchange
            success = IERC20(_tokenAddress).transferFrom(
                _publicParty,
                address(this),
                _amount
            );

            if (!success) {
                revert("Could not transfer token in.");
            } else {
                userAccounts[_publicParty].tokens[_tokenAddress] += _amount;
            }
        } else {
            // transfer token out of exchange
            success = IERC20(_tokenAddress).approve(_publicParty, _amount);
            success =
                IERC20(_tokenAddress).transfer(_publicParty, _amount) &&
                success;

            if (!success) {
                revert("Could not transfer token out.");
            } else {
                userAccounts[_publicParty].tokens[_tokenAddress] -= _amount;
            }
        }
    }

    /// Remove an order from the structure of type OP.
    /// @param _operation the type of order operation
    /// @param _id the id of the order
    /// @dev the method deletes an order from the doubly linked list ...
    /// preserving the order of orders both berfore and after
    function handle_remove_order(OP _operation, uint _id) internal {
        if (_operation == OP.Sell) {
            uint previousOrderId = sellSideExchange[sellSideIndex[_id]][_id]
                .previous;
            uint nextOrderId = sellSideExchange[sellSideIndex[_id]][_id].next;

            sellSideExchange[sellSideIndex[previousOrderId]][previousOrderId]
                .next = nextOrderId;

            if (nextOrderId > 0) {
                sellSideExchange[sellSideIndex[nextOrderId]][nextOrderId]
                    .previous = previousOrderId;
            }

            delete sellSideExchange[sellSideIndex[_id]][_id];
        } else {
            uint previousOrderId = buySideExchange[_id].previous;
            uint nextOrderId = buySideExchange[_id].next;

            buySideExchange[previousOrderId].next = nextOrderId;

            if (nextOrderId > 0) {
                buySideExchange[nextOrderId].previous = previousOrderId;
            }

            delete buySideExchange[_id];
        }
    }

    /// Release a global lock.
    /// @param _operation the type of operation being locked
    /// @dev once a lock is acquired, it is safe to operate on the structure ...
    /// ... of type OP
    function acquire_lock(OP _operation) internal {
        if (_operation == OP.Sell) {
            sellLock = true;
        } else if (_operation == OP.Buy) {
            buyLock = true;
        } else if (_operation == OP.Account) {
            accountLock = true;
        } else {
            accountLock = true;
            sellLock = true;
            buyLock = true;
        }
    }

    /// Release a global lock.
    /// @param _operation the type of operation being locked
    /// @dev once a lock is released, the OP structure must not be modified
    function release_lock(OP _operation) internal {
        if (_operation == OP.Sell) {
            sellLock = false;
        } else if (_operation == OP.Buy) {
            buyLock = false;
        } else if (_operation == OP.Account) {
            accountLock = false;
        } else {
            accountLock = false;
            buyLock = false;
            sellLock = false;
        }
    }

    /// Seek the closest (strictly older than if previously initialised) index ...
    /// ... to be used as an id within an Exchange
    /// @param _operation the type of operation for the id
    /// @dev the runtime of this method depends on whether the exchange data structures
    /// are fragmented, which will theoretically be determined as a product of both time and ...
    /// the volume of transactions through this Auction House.
    /// @return an index
    function seek_order_id(OP _operation) internal view returns (uint) {
        bool buyOp = _operation == OP.Buy;
        uint orderId = buyOp ? buyOrderId : sellOrderId;
        bool found = false;
        bool cycled = false;

        while (!found) {
            orderId += 1;

            // Check whether an overflow is about to occur.
            if (type(uint).max == orderId) {
                if (cycled) {
                    // already cycled before -- no key available
                    revert("Maximum order limit reached.");
                }
                cycled = true;
            }

            // Check whether the current orderId is occupied.
            if (buyOp) {
                found = !buySideExchange[orderId].exists ? true : found;
            } else {
                found = !sellSideExchange[sellSideIndex[orderId]][orderId]
                    .exists
                    ? true
                    : found;
            }
        }

        return orderId;
    }

    /// Match buy orders on the Buy Exchange to sell orders on the Sell Exchange ...
    /// by traversing buySideExchange from head (oldest transaction) to tail (newest transaction)
    function match_buy_sell_exchange() internal {
        BuyOrder memory currBuy = buySideExchange[GENESIS];
        while (true) {
            // check if current order is not blind
            if (currBuy.exists && currBuy.status == OrderStatus.Open) {
                // try fulfulling the current order
                // by matching lowest price <= current bid
                SellOrder memory currSell = sellSideExchange[currBuy.token][
                    GENESIS
                ];

                while (true) {
                    if (currSell.exists && currSell.price <= currBuy.price) {
                        // fulfil orders
                        if (currSell.amount == currBuy.amount) {
                            uint totalCost = currSell.price * currSell.amount;
                            execute_match(
                                currSell,
                                currBuy,
                                currSell.amount,
                                totalCost,
                                NONE
                            );
                            handle_remove_order(OP.Sell, currSell.id);
                            handle_remove_order(OP.Buy, currBuy.id);
                            // current buy order fulfiled; continue to next order
                            break;
                        }
                        if (currSell.amount > currBuy.amount) {
                            // fulfil sell order in part
                            uint totalCost = currSell.price * currBuy.amount;
                            execute_match(
                                currSell,
                                currBuy,
                                currBuy.amount,
                                totalCost,
                                userAccounts[currSell.owner].tokens[
                                    currSell.token
                                ] - currBuy.amount
                            );
                            sellSideExchange[currBuy.token][currSell.id]
                                .amount -= currBuy.amount;
                            handle_remove_order(OP.Buy, currBuy.id);
                            break;
                        }
                        if (currBuy.amount > currSell.amount) {
                            // fulfil buy order in part
                            uint totalCost = currSell.price * currSell.amount;
                            execute_match(
                                currSell,
                                currBuy,
                                currSell.amount,
                                totalCost,
                                NONE
                            );
                            buySideExchange[currBuy.id].amount -= currSell
                                .amount;
                            // buy order remains outstanding; continue
                        }
                        // reached the end of a sell order chain for the current token
                        if (currSell.next == NONE) {
                            break;
                        }
                        currSell = sellSideExchange[currBuy.token][
                            currSell.next
                        ];
                        handle_remove_order(OP.Sell, currSell.id);
                    } else {
                        // reached the end of a sell order chain for the current token
                        if (currSell.next == NONE) {
                            break;
                        }
                        currSell = sellSideExchange[currBuy.token][
                            currSell.next
                        ];
                    }
                }
            }
            // reached the end of the buy order chain
            if (currBuy.next == NONE) {
                break;
            }
            currBuy = buySideExchange[currBuy.next];
        }
    }

    // Execute match by brokering account data
    function execute_match(
        SellOrder memory _currSell,
        BuyOrder memory _currBuy,
        uint _amount,
        uint _totalCost,
        uint _remaining
    ) internal {
        require(
            userAccounts[_currBuy.owner].balance >= _totalCost,
            "User does not have enough funds to execute transaction."
        );

        // decrease buyer debt accrued
        userAccounts[_currBuy.owner].debtAccrued -= _totalCost;
        // decrease buyer balance
        userAccounts[_currBuy.owner].balance -= _totalCost;
        // increase buyer token ownership
        userAccounts[_currBuy.owner].tokens[_currSell.token] = _amount;
        // update seller balance
        userAccounts[_currSell.owner].balance += _totalCost;
        // update seller token ownership
        userAccounts[_currSell.owner].tokens[_currSell.token] = _remaining;
    }
}
