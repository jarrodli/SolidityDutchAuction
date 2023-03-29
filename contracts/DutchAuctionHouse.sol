// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

interface IERC20 {
    function transferFrom(
        address _from,
        address _to,
        uint _value
    ) external returns (bool success);
}

struct Account {
    uint balance; // amount in ETH
    mapping(address => bool) tokens; // token contracts
    bool exists; // flag for existence
}

contract DutchAuctionHouse {
    enum Modes {
        DepositWithdrawl,
        Offer,
        BidOpening,
        Matching
    }

    uint private constant DURATION = 5 minutes;
    uint private constant N_MODES = 4;
    uint private immutable creationTime;
    Modes private mode = Modes.DepositWithdrawl;

    mapping(address => Account) userAccounts;

    constructor() {
        creationTime = block.timestamp;
    }

    modifier during(Modes _mode) {
        poll_mode();
        require(mode == _mode, "Action not allowed during this mode.");
        _;
    }

    modifier account_unique(address _account) {
        require(
            !userAccounts[msg.sender].exists,
            "Account already exists. Action not allowed."
        );
        _;
    }

    modifier account_required(address _account) {
        require(
            userAccounts[msg.sender].exists,
            "Account payable does not exist. Action not allowed."
        );
        _;
    }

    function create_account() external payable account_unique(msg.sender) {
        Account storage acc = userAccounts[msg.sender];
        acc.balance = 0;
        acc.exists = true;

        handle_deposit_funds(msg.sender, msg.value);
    }

    function create_account(
        address _tokenAddress,
        uint _amount
    ) external payable account_unique(msg.sender) {
        Account storage acc = userAccounts[msg.sender];
        acc.balance = 0;
        acc.exists = true;

        handle_deposit_funds(msg.sender, msg.value);
        handle_deposit_token(msg.sender, _tokenAddress, _amount);
    }

    function deposit_funds()
        external
        payable
        during(Modes.DepositWithdrawl)
        account_required(msg.sender)
    {
        handle_deposit_funds(msg.sender, msg.value);
    }

    function withdraw_funds(
        address payable transferTo,
        uint _amount
    ) external during(Modes.DepositWithdrawl) account_required(msg.sender) {
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
    }

    function deposit_token(
        address _tokenAddress,
        uint _amount
    ) external during(Modes.DepositWithdrawl) account_required(msg.sender) {
        handle_deposit_token(msg.sender, _tokenAddress, _amount);
    }

    function withdraw_token(
        address _tokenAddress,
        uint _amount
    ) external during(Modes.DepositWithdrawl) {
        require(
            userAccounts[msg.sender].tokens[_tokenAddress],
            "User does not own token. Action not allowed."
        );

        // require(IERC20(_tokenAddress).balanceOf(address(this)) >= _amount, "");
    }

    function sell() external during(Modes.Offer) {}

    function withdraw_sell_offer() external during(Modes.Offer) {}

    function reduce_price() external during(Modes.Offer) {}

    function bid() external during(Modes.BidOpening) {}

    function withdraw_bid_offer() external during(Modes.BidOpening) {}

    function open_bid() external during(Modes.BidOpening) {}

    function init_match_phase() external during(Modes.Matching) {}

    function poll_mode() internal {
        // Determine the amount of time passed since the Auction genesis ...
        // ... in minutes.
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

    function handle_deposit_funds(address _address, uint _amount) internal {
        userAccounts[_address].balance += _amount;
    }

    function handle_deposit_token(
        address _sender,
        address _tokenAddress,
        uint _amount
    ) internal {
        bool success = IERC20(_tokenAddress).transferFrom(
            _sender,
            address(this),
            _amount
        );

        if (!success) {
            revert("Could not transfer token. Ingress failure.");
        } else {
            userAccounts[_sender].tokens[_tokenAddress] = true;
        }
    }

    // function check_account(address _account) internal {

    // }
}
