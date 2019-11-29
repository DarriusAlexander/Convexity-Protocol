
var expect = require('expect');
var OptionsContract = artifacts.require("../contracts/OptionsContract.sol");
var OptionsFactory = artifacts.require("../contracts/OptionsFactory.sol");
var OptionsExchange = artifacts.require("../contracts/OptionsExchange.sol");
var CompoundOracle = artifacts.require("../contracts/lib/MockCompoundOracle.sol");
var UniswapFactory = artifacts.require("../contracts/lib/MockUniswapFactory.sol");
var daiMock = artifacts.require("../contracts/lib/simpleERC20.sol");

const truffleAssert = require('truffle-assertions');

// Initialize the Options Factory, Options Exchange and other mock contracts
contract('OptionsContract', (accounts) => {
  var creatorAddress = accounts[0];
  var firstOwnerAddress = accounts[1];
  var secondOwnerAddress = accounts[2];
  /* create named accounts for contract roles */

  let optionsContracts;
  let optionsFactory;
  let optionsExchange;
  let dai;
  let compoundOracle;

  before(async () => {
    try {
      // 1. Deploy mock contracts
      // 1.1 Compound Oracle
      compoundOracle = await CompoundOracle.deployed();
      // 1.2 Uniswap Factory
      var uniswapFactory = await UniswapFactory.deployed();
      // 1.3 Mock Dai contract
      dai = await daiMock.deployed();

      // 2. Deploy our contracts
      // deploys the Options Exhange contract
      optionsExchange = await OptionsExchange.deployed();

      // TODO: remove this later. For now, set the compound Oracle and uniswap Factory addresses here.
      await optionsExchange.setUniswapAndCompound(uniswapFactory.address, compoundOracle.address);

      // Deploy the Options Factory contract and add assets to it
      optionsFactory = await OptionsFactory.deployed();
      await optionsFactory.setOptionsExchange(optionsExchange.address);

      await optionsFactory.addAsset(
        "DAI",
        dai.address
      );
      // TODO: deploy a mock USDC and get its address
      await optionsFactory.addAsset(
      "USDC",
      "0xB5D0545dF2649359B1F91679f64812dc70Bfd547"
      );

      // Create the unexpired options contract
      var optionsContractResult = await optionsFactory.createOptionsContract(
        "ETH",
        -"18",
        "DAI",
        -"17",
        "90",
        -"18",
        "USDC",
        "1577836800",
        "1577836800"
      );

      var optionsContractAddr = optionsContractResult.logs[0].args[0];
      optionsContracts = [await OptionsContract.at(optionsContractAddr)]

    } catch (err) {
      console.error(err);
    }

  });


  describe("#openRepo()", () => {
    it("should open first repo correctly", async () => {
      var result = await  optionsContracts[0].openRepo({from: creatorAddress, gas: '100000'})
      var repoIndex = "0";

      // test getReposByOwner
      var repos = await optionsContracts[0].getReposByOwner(creatorAddress);
      const expectedRepos =[ '0' ]
      expect(repos).toMatchObject(expectedRepos);

      // test getRepoByIndex
      var repo = await optionsContracts[0].getRepoByIndex(repoIndex);
      const expectedRepo = {
        '0': '0',
        '1': '0',
        '2': creatorAddress }
      expect(repo).toMatchObject(expectedRepo);

    })

    it("should open second repo correctly", async () => {

      var result = await  optionsContracts[0].openRepo({from: creatorAddress, gas: '100000'})
      var repoIndex = "1";

       // test getReposByOwner
       var repos = await optionsContracts[0].getReposByOwner(creatorAddress);
       const expectedRepos =[ '0', '1' ]
       expect(repos).toMatchObject(expectedRepos);

       // test getRepoByIndex
       var repo = await optionsContracts[0].getRepoByIndex(repoIndex);
       const expectedRepo = {
         '0': '0',
         '1': '0',
         '2': creatorAddress }
       expect(repo).toMatchObject(expectedRepo);
    })

    it("new person should be able to open third repo correctly", async () => {

      var result = await  optionsContracts[0].openRepo({from: firstOwnerAddress, gas: '100000'})
      var repoIndex = "2";

       // test getReposByOwner
       var repos = await optionsContracts[0].getReposByOwner(firstOwnerAddress);
       const expectedRepos =[ '2' ]
       expect(repos).toMatchObject(expectedRepos);

       // test getRepoByIndex
       var repo = await optionsContracts[0].getRepoByIndex(repoIndex);
       const expectedRepo = {
         '0': '0',
         '1': '0',
         '2': firstOwnerAddress }
       expect(repo).toMatchObject(expectedRepo);
    })
  });

  describe("#addETHCollateral()", () => {


    it("should add ETH collateral successfully", async () => {
      const repoNum = 1;
      var msgValue = "10000000";
      var result = await  optionsContracts[0].addETHCollateral(repoNum,{from: creatorAddress, gas: '100000', value: msgValue})

      // test that the repo's balances have been updated.
      var repo = await optionsContracts[0].getRepoByIndex(repoNum);
      const expectedRepo = {
        '0': '10000000',
        '1': '0',
        '2': creatorAddress }
      expect(repo).toMatchObject(expectedRepo);

    })

    it("anyone should be able to add ETH collateral to any repo", async()=> {
      const repoNum = 1;
      var msgValue = "10000000";
      var result = await  optionsContracts[0].addETHCollateral(repoNum,{from: firstOwnerAddress, gas: '100000', value: msgValue})

      // test that the repo's balances have been updated.
      var repo = await optionsContracts[0].getRepoByIndex(repoNum);
      const expectedRepo = {
        '0': '20000000',
        '1': '0',
        '2': creatorAddress }
      expect(repo).toMatchObject(expectedRepo);
    })

    it("should not be able to add ETH collateral to an expired options contract", async () => {
      try{
        const repoNum = 1;
        var msgValue = "10000000";
        var result = await  optionsContracts[1].addETHCollateral(repoNum,{from: firstOwnerAddress, gas: '100000', value: msgValue})
      } catch (err) {
        return;
      }
      truffleAssert.fails("should throw error");
    })

  });

  describe("#issueOptionTokens()", () => {
    it("should allow you to mint correctly", async () => {

      const repoIndex = "1";
      const numTokens = "27777777";

      var result = await  optionsContracts[0].issueOptionTokens(repoIndex, numTokens,{from: creatorAddress, gas: '100000'});
      var amtPTokens = await optionsContracts[0].balanceOf(creatorAddress);
      expect(amtPTokens).toBe(numTokens);
    })

    it("only owner should of repo should be able to mint", async () => {
      const repoIndex = "1";
      const numTokens = "100";
      try {
        var result = await  optionsContracts[0].issueOptionTokens(repoIndex, numTokens,{from: firstOwnerAddress, gas: '100000'});
      } catch (err) {
        return;
      }
      truffleAssert.fails("should throw error");

      // the balance of the contract caller should be 0. They should not have gotten tokens.
      var amtPTokens = await optionsContracts[0].balanceOf(firstOwnerAddress);
      console.log(amtPTokens);
      expect(amtPTokens).toBe("0");

    })

    it ("should only allow you to mint tokens if you have sufficient collateral", async () => {
      const repoIndex = "1";
      const numTokens = "2";
      try {
        var result = await  optionsContracts[0].issueOptionTokens(repoIndex, numTokens,{from: creatorAddress, gas: '100000'});
      } catch (err) {
        return;
      }

      truffleAssert.fails("should throw error");

      // the balance of the contract caller should be 0. They should not have gotten tokens.
      var amtPTokens = await optionsContracts[0].balanceOf(creatorAddress);
      expect(amtPTokens).toBe("27777777");
    })

  });

  describe('#burnPutTokens()', () => {
    it("should be able to burn put tokens", async () => {
      const repoIndex = "1";
      const numTokens = "10";

      var result = await  optionsContracts[0].burnPutTokens(repoIndex, numTokens,{from: creatorAddress, gas: '100000'});
      var amtPTokens = await optionsContracts[0].balanceOf(creatorAddress);
      expect(amtPTokens).toBe("27777767");

      var repo = await optionsContracts[0].getRepoByIndex(repoIndex);
      const expectedRepo = {
        '0': '20000000',
        '1': '27777767',
        '2': creatorAddress }
      expect(repo).toMatchObject(expectedRepo);
      
    })

    it("only owner should be able to burn tokens", async () => {
      var transferred = await optionsContracts[0].transfer(firstOwnerAddress, "10",{from: creatorAddress, gas: '100000'});
      var amtPTokens = await optionsContracts[0].balanceOf(firstOwnerAddress);
      expect(amtPTokens).toBe("10");

      const repoIndex = "1";
      const numTokens = "10";

      try {
      var result = await  optionsContracts[0].burnPutTokens(repoIndex, numTokens,{from: firstOwnerAddress, gas: '100000'});
      } catch (err) {
        return;
      }

      truffleAssert.fails("should throw error");
  })

  })


  describe("#liquidate()", () => {
      it("Repo should be unsafe when the price drops", async () => {
          // Make sure Repo is safe before price drop
          await optionsContracts[0].isUnsafe("1");
          var returnValues = (await optionsContracts[0].getPastEvents( 'unsafeCalled', { fromBlock: 0, toBlock: 'latest' } ));
          var unsafe = returnValues[0].returnValues.isUnsafe;
          expect(unsafe).toBe(false);

          // change the oracle price: 
          await compoundOracle.updatePrice("100");

        // Make sure repo is unsafe after price drop
          var unsafe = await optionsContracts[0].isUnsafe("1");
          var returnValues = (await optionsContracts[0].getPastEvents( 'unsafeCalled', { fromBlock: 0, toBlock: 'latest' } ));
          var unsafe = returnValues[1].returnValues.isUnsafe;
          expect(unsafe).toBe(true);
      })

      it("Should not be able to liquidate more than collateral factor when the price drops", async () => {
        // Try to liquidate the repo
        try {
            await optionsContracts[0].liquidate("1", "11001105",{from: firstOwnerAddress, gas: '100000'});
        } catch (err) {
            return; 
        }

        truffleAssert.fails("should throw err");
        })

      it("Should be able to liquidate when the price drops", async () => {
          const repoIndex = "1"
          //Liquidator first needs oTokens
          await optionsContracts[0].transfer(firstOwnerAddress, "11001100",{from: creatorAddress, gas: '100000'});
          var amtPTokens = await optionsContracts[0].balanceOf(firstOwnerAddress);
          expect(amtPTokens).toBe("11001110");

          // Approve before burn
          await optionsContracts[0].approve(optionsContracts[0].options.address, "10000000000000000",{from: firstOwnerAddress});

          // Try to liquidate the repo
          await optionsContracts[0].liquidate(repoIndex, "11001100",{from: firstOwnerAddress, gas: '100000'});

          // Check that the correct liquidate events are emitted
          var returnValues = (await optionsContracts[0].getPastEvents( 'Liquidate', { fromBlock: 0, toBlock: 'latest' } ));
          expect(returnValues[0].returnValues.amtCollateralToPay).toBe('9999999');

          // check that the repo balances have changed
          var repo = await optionsContracts[0].getRepoByIndex(repoIndex);
          const expectedRepo = {
            '0': '10000001',
            '1': '16776667',
            '2': creatorAddress }
          expect(repo).toMatchObject(expectedRepo);

          // check that the liquidator balances have changed 
          var amtPTokens = await optionsContracts[0].balanceOf(firstOwnerAddress);
          expect(amtPTokens).toBe("10");
          // TODO: how to check that collateral has increased? 
          
      })

      it("should be able to liquidate if still undercollateralized", async() => {
        const repoIndex = "1"
        //Liquidator first needs oTokens
        await optionsContracts[0].transfer(firstOwnerAddress, "1000",{from: creatorAddress, gas: '100000'});
        var amtPTokens = await optionsContracts[0].balanceOf(firstOwnerAddress);
        expect(amtPTokens).toBe("1010");

        // Approve before burn
        await optionsContracts[0].approve(optionsContracts[0].options.address, "10000000000000000",{from: firstOwnerAddress});

        // Try to liquidate the repo
        await optionsContracts[0].liquidate(repoIndex, "1000",{from: firstOwnerAddress, gas: '100000'});

        // Check that the correct liquidate events are emitted
        var returnValues = (await optionsContracts[0].getPastEvents( 'Liquidate', { fromBlock: 0, toBlock: 'latest' } ));
        expect(returnValues[1].returnValues.amtCollateralToPay).toBe('909');

        // check that the repo balances have changed
        var repo = await optionsContracts[0].getRepoByIndex(repoIndex);
        const expectedRepo = {
          '0': '9999092',
          '1': '16775667',
          '2': creatorAddress }
        expect(repo).toMatchObject(expectedRepo);

        // check that the liquidator balances have changed 
        var amtPTokens = await optionsContracts[0].balanceOf(firstOwnerAddress);
        expect(amtPTokens).toBe("10");
        // TODO: how to check that collateral has increased? 
        
      })

      it("should not be able to liquidate if safe")


  })

});