const { expectRevert } = require("@openzeppelin/test-helpers");

const DutchAuctionHouse = artifacts.require("DutchAuctionHouse");
const ERC20PresetFixedSupply = artifacts.require("ERC20PresetFixedSupply");

contract("DutchAuctionHouse", (accounts) => {
    const NONE = 0;
    const NONE_BYTES = web3.eth.abi.encodeParameter("uint", String(NONE));

    let Exchange;
    let ERC20Instance;

    const privateKeys = [
        "0x5c7a050c7b0e3a6896e9667a6dff3a6b389c665aaed218c352071890c05520ee",
    ];

    it("should setup the account state correctly", async () => {
        // create a Dutch Auction House
        Exchange = await DutchAuctionHouse.deployed();
        // // setup pki
        // acc0 = await web3.eth.accounts.create();
        // acc1 = await web3.eth.accounts.create();

        // create a wealthy observer account
        await Exchange.create_account({ from: accounts[0], value: 100000 });
        // create a primary buyer account (buyer 1)
        await Exchange.create_account({ from: accounts[1], value: 0 });
        // create a secondary buyer account (buyer 2)
        await Exchange.create_account({ from: accounts[2], value: 0 });

        // create a primary seller account (seller 1)
        await Exchange.create_account({ from: accounts[3], value: 0 });
        // create a secondary seller account (seller 2)
        await Exchange.create_account({ from: accounts[4], value: 0 });

        // create mock ERC20 token and transfer to central bank account
        ERC20Instance = await ERC20PresetFixedSupply.new(
            "ERC20",
            "E20",
            750000,
            accounts[0]
        );

        // distribute ERC20 token to sellers
        ERC20Instance.transfer(accounts[3], 500000);
        ERC20Instance.transfer(accounts[4], 250000);
    });

    it("should handle account creation correctly", async () => {
        let balance = await web3.eth.getBalance(Exchange.address);

        await expectRevert(
            Exchange.create_account({ from: accounts[1] }),
            "Account already exists. Action not allowed."
        );

        return assert.isTrue(balance == 100000);
    });

    it("should handle ETH deposits and withdrawal correctly", async () => {
        await expectRevert(
            Exchange.deposit_funds({ from: accounts[7], value: 1000 }),
            "Account payable does not exist. Action not allowed."
        );

        await expectRevert(
            Exchange.withdraw_funds(accounts[7], 0, { from: accounts[7] }),
            "Account payable does not exist. Action not allowed."
        );

        await Exchange.deposit_funds({ from: accounts[3], value: 1000 });

        // drain the account
        await Exchange.withdraw_funds(accounts[3], 1000, { from: accounts[3] });

        // try and transfer out more money
        await expectRevert(
            Exchange.withdraw_funds(accounts[3], 1, { from: accounts[3] }),
            "Insufficient balance. Action not allowed."
        );
    });

    it("should handle token deposit and withdrawal correctly", async () => {
        await ERC20Instance.approve(Exchange.address, 500000, {
            from: accounts[3],
        });
        await ERC20Instance.approve(Exchange.address, 250000, {
            from: accounts[4],
        });

        await Exchange.deposit_token(ERC20Instance.address, 500000, {
            from: accounts[3],
        });
        await Exchange.deposit_token(ERC20Instance.address, 250000, {
            from: accounts[4],
        });

        const test0 = (await ERC20Instance.balanceOf(accounts[3])) == 0;
        const test1 = (await ERC20Instance.balanceOf(accounts[4])) == 0;

        await Exchange.withdraw_token(ERC20Instance.address, 500000, {
            from: accounts[3],
        });
        await Exchange.withdraw_token(ERC20Instance.address, 250000, {
            from: accounts[4],
        });

        const test2 = (await ERC20Instance.balanceOf(accounts[3])) == 500000;
        const test3 = (await ERC20Instance.balanceOf(accounts[4])) == 250000;

        return assert.isTrue(test1 && test2 && test3 && test0);
    });

    it("should handle place and withdraw sell orders correctly", async () => {
        await expectRevert(
            Exchange.sell(ERC20Instance.address, 250000, 1, {
                from: accounts[3],
            }),
            "User does not own token. Action not allowed."
        );

        await ERC20Instance.approve(Exchange.address, 1, { from: accounts[3] });
        await Exchange.deposit_token(ERC20Instance.address, 1, {
            from: accounts[3],
        });

        await expectRevert(
            Exchange.sell(ERC20Instance.address, 2, 1, { from: accounts[3] }),
            "User does not own enough of the specified token."
        );

        await ERC20Instance.approve(Exchange.address, 499999, {
            from: accounts[3],
        });
        await Exchange.deposit_token(ERC20Instance.address, 499999, {
            from: accounts[3],
        });
        const tx = await Exchange.sell(ERC20Instance.address, 500000, 1, {
            from: accounts[3],
        });
        const transaction0ID = tx.receipt.logs[0].args[0];

        await expectRevert(
            Exchange.withdraw_sell_order(999999, { from: accounts[3] }),
            "User has no sell order with corresponding id. Action not allowed."
        );
        await Exchange.withdraw_sell_order(transaction0ID, {
            from: accounts[3],
        });

        await Exchange.withdraw_token(ERC20Instance.address, 500000, {
            from: accounts[3],
        });
    });

    it("should handle place, withdraw and reveal buy orders correctly", async () => {
        const failingBlindBid = web3.utils.soliditySha3(
            ERC20Instance.address,
            1000000,
            10,
            2
        );

        const tx0 = await Exchange.buy(
            failingBlindBid,
            false,
            NONE,
            NONE_BYTES,
            NONE_BYTES,
            { from: accounts[1] }
        );
        const transaction0ID = tx0.receipt.logs[0].args[0];

        await expectRevert(
            Exchange.open_buy_order(
                transaction0ID,
                ERC20Instance.address,
                10,
                10,
                2,
                { from: accounts[1] }
            ),
            "Buy order missmatch. Cannot open diverging bid."
        );

        await expectRevert(
            Exchange.open_buy_order(
                transaction0ID,
                ERC20Instance.address,
                1000000,
                10,
                2,
                { from: accounts[1] }
            ),
            "User is unable to service this bid. Cannot open bid."
        );

        const passingBlindBid = web3.utils.soliditySha3(
            ERC20Instance.address,
            10,
            10,
            2
        );

        const tx1 = await Exchange.buy(
            passingBlindBid,
            false,
            NONE,
            NONE_BYTES,
            NONE_BYTES,
            { from: accounts[1] }
        );
        const transaction1ID = tx1.receipt.logs[0].args[0];

        await Exchange.deposit_funds({ from: accounts[1], value: 100 });

        await Exchange.open_buy_order(
            transaction1ID,
            ERC20Instance.address,
            10,
            10,
            2,
            { from: accounts[1] }
        );

        await expectRevert(
            Exchange.withdraw_buy_order(999999, { from: accounts[1] }),
            "User has no buy order with corresponding id. Action not allowed."
        );

        await Exchange.withdraw_buy_order(transaction1ID, {
            from: accounts[1],
        });

        await Exchange.withdraw_funds(accounts[1], 100, { from: accounts[1] });
    });

    it("should handle matching buy and sell orders successfully", async () => {
        // move tokens to seller accounts
        await ERC20Instance.approve(Exchange.address, 5, { from: accounts[3] });
        await Exchange.deposit_token(ERC20Instance.address, 5, {
            from: accounts[3],
        });
        await ERC20Instance.approve(Exchange.address, 10, {
            from: accounts[4],
        });
        await Exchange.deposit_token(ERC20Instance.address, 10, {
            from: accounts[4],
        });

        // setup sell orders
        const tx0 = await Exchange.sell(ERC20Instance.address, 5, 3, {
            from: accounts[3],
        });
        const transaction0ID = tx0.receipt.logs[0].args[0];
        const tx1 = await Exchange.sell(ERC20Instance.address, 10, 2, {
            from: accounts[4],
        });
        const transaction1ID = tx1.receipt.logs[0].args[0];

        // setup blind bids
        const blindBid0 = web3.utils.soliditySha3(
            ERC20Instance.address,
            3,
            5,
            100
        );
        const blindBid1 = web3.utils.soliditySha3(
            ERC20Instance.address,
            2,
            20,
            100
        );
        const blindBid2 = web3.utils.soliditySha3(
            ERC20Instance.address,
            100,
            100,
            100
        );

        // place buy orders
        const tx2 = await Exchange.buy(
            blindBid0,
            false,
            NONE,
            NONE_BYTES,
            NONE_BYTES,
            { from: accounts[1] }
        );
        const transaction2ID = tx2.receipt.logs[0].args[0];
        const tx3 = await Exchange.buy(
            blindBid1,
            false,
            NONE,
            NONE_BYTES,
            NONE_BYTES,
            { from: accounts[2] }
        );
        const transaction3ID = tx3.receipt.logs[0].args[0];
        const tx4 = await Exchange.buy(
            blindBid2,
            false,
            NONE,
            NONE_BYTES,
            NONE_BYTES,
            { from: accounts[2] }
        );
        const transaction4ID = tx4.receipt.logs[0].args[0];

        // deposit ETH
        await Exchange.deposit_funds({ from: accounts[1], value: 15 });
        await Exchange.deposit_funds({ from: accounts[2], value: 40 });

        // open some buy orders
        await Exchange.open_buy_order(
            transaction2ID,
            ERC20Instance.address,
            3,
            5,
            100,
            { from: accounts[1] }
        );
        await Exchange.open_buy_order(
            transaction3ID,
            ERC20Instance.address,
            2,
            20,
            100,
            { from: accounts[2] }
        );

        // start matching
        await Exchange.init_match_phase({
            from: accounts[1],
        });

        // withdraw the remaining blind bid
        await Exchange.withdraw_buy_order(transaction4ID, {
            from: accounts[2],
        });

        // attempt to withdraw all fulfiled orders
        await expectRevert(
            Exchange.withdraw_sell_order(transaction0ID, { from: accounts[1] }),
            "User has no sell order with corresponding id. Action not allowed."
        );
        await expectRevert(
            Exchange.withdraw_sell_order(transaction1ID, { from: accounts[2] }),
            "User has no sell order with corresponding id. Action not allowed."
        );
        await expectRevert(
            Exchange.withdraw_buy_order(transaction0ID, { from: accounts[3] }),
            "User has no buy order with corresponding id. Action not allowed."
        );
        await expectRevert(
            Exchange.withdraw_buy_order(transaction1ID, { from: accounts[4] }),
            "User has no buy order with corresponding id. Action not allowed."
        );

        // drain buyer 1 account
        await Exchange.withdraw_funds(accounts[1], 5, { from: accounts[1] });
        // expect buyer 1 account to be drained
        await expectRevert(
            Exchange.withdraw_funds(accounts[1], 1, { from: accounts[1] }),
            "Insufficient balance. Action not allowed."
        );

        // expect buyer 2 account to have 30 ETH remaining
        await Exchange.withdraw_funds(accounts[2], 30, { from: accounts[2] });
        await expectRevert(
            Exchange.withdraw_funds(accounts[2], 1, { from: accounts[2] }),
            "Insufficient balance. Action not allowed."
        );

        // expect seller 2 account to be empty (sold nothing!)
        await expectRevert(
            Exchange.withdraw_funds(accounts[3], 1, { from: accounts[3] }),
            "Insufficient balance. Action not allowed."
        );

        // drain seller 2 account (sold everything!)
        await Exchange.withdraw_funds(accounts[4], 20, { from: accounts[4] });
        // expect seller 2 account to be empty
        await expectRevert(
            Exchange.withdraw_funds(accounts[4], 1, { from: accounts[4] }),
            "Insufficient balance. Action not allowed."
        );
    });

    it("should handle third party blind-bids", async () => {
        const blindBid = await web3.utils.soliditySha3(
            ERC20Instance.address,
            10,
            10,
            2
        );

        // create a signedBlindBid from wealthy observer who previously
        // did not wish to participate on account of their wealth
        const sig = await web3.eth.accounts.sign(blindBid, privateKeys[0]);

        // test that the privateKey is truly private -- it is not an account address
        assert.isTrue(privateKeys[0] != accounts[0]);

        // test recover works locally
        assert.isTrue(
            web3.eth.accounts.recover(blindBid, sig.signature) == accounts[0]
        );

        await Exchange.deposit_funds({ from: accounts[0], value: 100 });

        // place buy order with a different account
        const tx0 = await Exchange.buy(blindBid, true, sig.v, sig.r, sig.s, {
            from: accounts[1],
        });
        const transaction0ID = tx0.receipt.logs[0].args[0];

        // attempt opening buy order with wrong account
        await expectRevert(
            Exchange.open_buy_order(
                transaction0ID,
                ERC20Instance.address,
                10,
                10,
                2,
                { from: accounts[1] }
            ),
            "Signature recovery failure. Cannot operate on another users bid."
        );

        // open buy order with correct account
        await Exchange.open_buy_order(
            transaction0ID,
            ERC20Instance.address,
            10,
            10,
            2,
            { from: accounts[0] }
        );

        // withdraw the buy order
        await expectRevert(
            Exchange.withdraw_buy_order(transaction0ID, {
                from: accounts[1],
            }),
            "Signature recovery failure. Cannot operate on another users bid."
        );

        // withdraw the buy order
        await Exchange.withdraw_buy_order(transaction0ID, {
            from: accounts[0],
        });

        // cleanup
        await Exchange.withdraw_funds(accounts[0], 100, { from: accounts[0] });
    });
});
