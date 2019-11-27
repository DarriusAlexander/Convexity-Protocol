pragma solidity 0.5.10;

import "./lib/CompoundOracleInterface.sol";
import "./OptionsExchange.sol";
import "./OptionsUtils.sol";
import "./lib/UniswapFactoryInterface.sol";
import "./lib/UniswapExchangeInterface.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

/**
 * @title Opyn's Options Contract
 * @author Opyn
 */
contract OptionsContract is OptionsUtils, ERC20 {
    using SafeMath for uint256;

    struct Number {
        uint256 value;
        int32 exponent; 
    }

    // Keeps track of the collateral, debt for each repo. 
    struct Repo {
        uint256 collateral;
        uint256 putsOutstanding;
        address payable owner;
    }

    OptionsExchange public optionsExchange; 

    Repo[] public repos; 

    // 1010 is 1.010. i.e. 1% incentive. 
    Number liquidationIncentive = Number(1010, -3);

    // 2 decimal places -> egs. 10.02%
    Number transactionFee; 

    /* 500 is 0.5. Max amount that a repo can be liquidated by i.e. 
    max collateral that can be taken in one function call */
    Number liquidationFactor = Number(500, -3); 

    /* 1054 is 1.054 i.e. 5.4% liqFee. 
    The fees paid to our protocol every time a liquidation happens */
    Number liquidationFee = Number(1000, -3);

    /* UNIX time. 
    Exercise period starts at `(expiry - windowSize)` and ends at `expiry` */ 
    uint256 windowSize; 
    
    /* The total collateral withdrawn from the Options Contract every time 
    the exercise function is called */
    uint256 totalExercised;

    /* The total amount of underlying that is added to the contract during the exercise window. 
    This number can only increase and is only incremented in the exercise function. After expiry, 
    this value is used to calculate the proportion of underlying paid out to the respective repo 
    owners in the claim collateral function. */
    uint256 totalUnderlying; 

    /* The totalCollateral is only updated on add, remove, liquidate. After expiry, 
    this value is used to calculate the proportion of underlying paid out to the respective repo 
    owner in the claim collateral function. The amount of collateral any repo owner gets back is 
    caluculated as below:
    repo.collateral / totalCollateral * (totalCollateral - totalExercised) */
    uint256 totalCollateral;

    /* 16 means 1.6. The minimum ratio of a repo's collateral to insurance promised. 
    The ratio is calculated as below:
    repo.collateral / (repo.putsOutstanding * strikePrice) */
    Number public collateralizationRatio = Number(16, -1); 

    // The collateral asset
    IERC20 public collateral;

    // The precision of the collateral
    int32 collateralExp = -18;

    // The asset being protected by the insurance
    IERC20 public underlying;

    // The amount of insurance promised per oToken
    Number public strikePrice;

    // The asset in which insurance is denominated in.
    IERC20 public strike;

    // The time of expiry of the options contract
    uint256 public expiry;

    // The amount of underlying that 1 oToken protects. 
    Number public oTokenExchangeRate = Number(1, -18);

    // TODO: how to change collateralizationRatio, liquidationFactor, liquidationFee, liquidationIncentive 
    // TODO: function to take out fees 

    /* @notice: constructor
        @param _collateral: The collateral asset
        @param _collExp: The precision of the collateral (-18 if ETH)
        @param _underlying: The asset that is being protected
        @param _oTokenExchangeExp: The precision of the `amount of underlying` that 1 oToken protects
        @param _strikePrice: The amount of strike asset that will be paid out
        @param _strikeExp: The precision of the strike asset (-18 if ETH)
        @param _strike: The asset in which the 
        @param _expiry: The time at which the insurance expires
        @param OptionsExchange: The contract which interfaces with the exchange + oracle 
        @param _windowSize: UNIX time. Exercise window is from `expiry - _windowSize` to `expiry`. */
    constructor(
        IERC20 _collateral,
        int32 _collExp,
        IERC20 _underlying,
        int32 _oTokenExchangeExp,
        uint256 _strikePrice,
        int32 _strikeExp,
        IERC20 _strike,
        uint256 _expiry,
        OptionsExchange _optionsExchange,
        uint256 _windowSize

    )
        OptionsUtils(
            //  address(_optionsExchange.UNISWAP_FACTORY())
            // address(_optionsExchange.UNISWAP_FACTORY()), address(_optionsExchange.COMPOUND_ORACLE())
        )
        public
    {
        collateral = _collateral;
        collateralExp = _collExp;

        underlying = _underlying;
        oTokenExchangeRate = Number(1, _oTokenExchangeExp);

        strikePrice = Number(_strikePrice, _strikeExp);
        strike = _strike;

        expiry = _expiry;
        optionsExchange = _optionsExchange;
        windowSize = _windowSize;

        // TODO: remove this later. 
        setUniswapAndCompound(address(_optionsExchange.UNISWAP_FACTORY()), address(_optionsExchange.COMPOUND_ORACLE()));
    }

    event RepoOpened(uint256 repoIndex);
    event ETHCollateralAdded(uint256 repoIndex, uint256 amount);
    event ERC20CollateralAdded(uint256 repoIndex, uint256 amount);
    event IssuedOptionTokens(address issuedTo);
    // TODO: remove safe + unsafe called once testing is done
    event safe(uint256 leftVal, uint256 rightVal, int32 leftExp, int32 rightExp, bool isSafe);
    event unsafeCalled(bool isUnsafe);
    event Liquidate (uint256 amtCollateralToPay);
    event Exercise (uint256 amtUnderlyingToPay, uint256 amtCollateralToPay);
    event ClaimedCollateral(uint256 amtCollateralClaimed, uint256 amtUnderlyingClaimed);

    function numRepos() public returns (uint256) {
        return repos.length; 
    }

    function openRepo() public returns (uint) {
        require(now < expiry, "Options contract expired");
        repos.push(Repo(0, 0, msg.sender));
        uint256 repoIndex = repos.length - 1;
        emit RepoOpened(repoIndex);
        return repoIndex;
    }

    function addETHCollateral(uint256 _repoNum) public payable returns (uint256) {
        //TODO: do we need to have require checks? do we need require msg.value > 0 ?
        //TODO: does it make sense to have the event emitted here or should it be in the helper function?
        require(isETH(collateral), "ETH is not the specified collateral type");
        emit ETHCollateralAdded(_repoNum, msg.value);
        return _addCollateral(_repoNum, msg.value);
    }

    function addERC20Collateral(uint256 _repoNum, uint256 _amt) public returns (uint256) {
        require(
            collateral.transferFrom(msg.sender, address(this), _amt),
            "Could not transfer in collateral tokens"
        );

        emit ERC20CollateralAdded(_repoNum, _amt);
        return _addCollateral(_repoNum, _amt);
    }

    /* @notice this function returns the exponential that the underlying token is. 
    If the underlying has a precision of 18 digits and the oTokenExchange is 14 digits 
    of precision, the underlyingExp is 4. 
    */
    function underlyingExp() internal returns (uint32) {
        // TODO: change this to be _oTokenExhangeExp - decimals(underlying)
        return uint32(oTokenExchangeRate.exponent - (-18));
    }

/// TODO: look up pToken to underlying ratio. rn 1:1.
/// TODO: add fees
/* @dev: 1 oToken protects against 10 * lowest precision of underlying. */
    function exercise(uint256 _oTokens) public payable {
        // 1. before exercise window: revert
        require(now >= expiry - windowSize, "Too early to exercise");
        require(now < expiry, "Beyond exercise time");

        // 2. during exercise window: exercise
        // 2.1 ensure person calling has enough pTokens
        require(balanceOf(msg.sender) >= _oTokens, "Not enough pTokens");

        // 2.2 check they have corresponding number of underlying (and transfer in)
        uint256 amtUnderlyingToPay = _oTokens.mul(10 ** underlyingExp());
        if (isETH(underlying)) {
            require(msg.value == amtUnderlyingToPay, "Incorrect msg.value");
        } else {
            require(
                underlying.transferFrom(msg.sender, address(this), amtUnderlyingToPay),
                "Could not transfer in tokens"
            );
        }

        totalUnderlying = totalUnderlying.add(amtUnderlyingToPay);

        // 2.3 transfer in oTokens
        _burn(msg.sender, _oTokens);

        /// 2.4 payout enough collateral to get strikePrice * pTokens amount of collateral
        // Get price from oracle
        uint256 ethToCollateralPrice = getPrice(address(collateral));
        uint256 ethToStrikePrice = getPrice(address(strike));
 
        // calculate how much should be paid out        
        uint256 amtCollateralToPayNum = _oTokens.mul(strikePrice.value).mul(ethToCollateralPrice);
        int32 amtCollateralToPayExp = strikePrice.exponent - collateralExp;
        uint256 amtCollateralToPay = 0;
        if(amtCollateralToPayExp > 0) {
            uint32 exp = uint32(amtCollateralToPayExp);
            amtCollateralToPay = amtCollateralToPayNum.mul(10 ** exp).div(ethToStrikePrice);
        } else {
            uint32 exp = uint32(-1 * amtCollateralToPayExp);
            amtCollateralToPay = (amtCollateralToPayNum.div(10 ** exp)).div(ethToStrikePrice);
        }

        totalExercised = totalExercised.add(amtCollateralToPay);

        emit Exercise(amtUnderlyingToPay, amtCollateralToPay);

        // Pay out collateral
        transferCollateral(msg.sender, amtCollateralToPay);
    }

    function getReposByOwner(address _owner) public view returns (uint[] memory) {
        uint[] memory reposOwned;
        uint256 count = 0;
        uint index = 0;

        // get length necessary for returned array
        for (uint256 i = 0; i < repos.length; i++) {
            if(repos[i].owner == _owner){
                count += 1;
            }
        }

        reposOwned = new uint[](count);

        // get each index of each repo owned by given address
        for (uint256 i = 0; i < repos.length; i++) {
            if(repos[i].owner == _owner) {
                reposOwned[index++] = i;
            }
        }

       return reposOwned;
    }

    function getRepoByIndex(uint256 repoIndex) public view returns (uint256, uint256, address) {
        Repo storage repo = repos[repoIndex];

        return (
            repo.collateral,
            repo.putsOutstanding,
            repo.owner
        );
    }

    function isETH(IERC20 _ierc20) public pure returns (bool) {
        return _ierc20 == IERC20(0);
    }

    function _addCollateral(uint256 _repoNum, uint256 _amt) private returns (uint256) {
        require(now < expiry, "Options contract expired");

        Repo storage repo = repos[_repoNum];

        repo.collateral = repo.collateral.add(_amt);

        totalCollateral = totalCollateral.add(_amt);

        return repo.collateral;
    }

    /*
    @notice: This function is called to issue the option tokens
    @dev: The owner of a repo should only be able to have a max of 
    floor(Collateral * collateralToStrike / (minCollateralizationRatio * strikePrice)) tokens issued. 
    @param repoIndex : The index of the repo to issue tokens from
    @param numTokens : The number of tokens to issue
    */
    function issueOptionTokens (uint256 repoIndex, uint256 numTokens) public {
        //check that we're properly collateralized to mint this number, then call _mint(address account, uint256 amount)
        require(now < expiry, "Options contract expired");

        Repo storage repo = repos[repoIndex];
        require(msg.sender == repo.owner, "Only owner can issue options");
    
        // checks that the repo is sufficiently collateralized 
        uint256 newNumTokens = repo.putsOutstanding.add(numTokens);
        require(isSafe(repo.collateral, newNumTokens), "unsafe to mint");
        _mint(msg.sender, numTokens);
        repo.putsOutstanding = newNumTokens;

        // TODO: figure out proper events:
        emit IssuedOptionTokens(msg.sender);
        return;
    }

    // this function opens a repo, adds ETH collateral, and mints new putTokens in one step, returing the repoIndex
    // function createOptionETHCollateral(uint256 amtToCreate) payable external returns (uint256) {
    //     require(isETH(collateral), "cannot add ETH as collateral to an ERC20 collateralized option");
    //     uint256 repoIndex = openRepo();
    //     //TODO: can ETH be passed around payables like this?
    //     createOptionETHCollateral(amtToCreate, repoIndex);
    //     return repoIndex;
    // }

    // //this function adds ETH collateral to an existing repo and mints new tokens in one step
    // function createOptionETHCollateral(uint256 amtToCreate, uint256 repoIndex) public payable {
    //     require(isETH(collateral), "cannot add ETH as collateral to an ERC20 collateralized option");
    //     require(repos[repoIndex].owner == msg.sender, "trying to createOption on a repo that is not yours");
    //     //TODO: can ETH be passed around payables like this?
    //     addETHCollateral(repoIndex);
    //     issueOptionTokens(repoIndex, amtToCreate);
    // }

    // //this function opens a repo, adds ERC20 collateral to that repo and mints new tokens in one step, returning the repoIndex
    // function createOptionERC20Collateral(uint256 amtToCreate, uint256 amtCollateral) external returns (uint256) {
    //     //TODO: was it okay to remove the require here?
    //     uint256 repoIndex = openRepo();
    //     createOptionERC20Collateral(repoIndex, amtToCreate, amtCollateral);
    //     return repoIndex;
    // }

    // //this function adds ERC20 collateral to an existing repo and mints new tokens in one step
    // function createOptionERC20Collateral(uint256 amtToCreate, uint256 amtCollateral, uint256 repoIndex) public {
    //     require(!isETH(collateral), "cannot add ERC20 collateral to an ETH collateralized option");
    //     require(repos[repoIndex].owner == msg.sender, "trying to createOption on a repo that is not yours");
    //     addERC20Collateral(repoIndex, amtCollateral);
    //     issueOptionTokens(repoIndex, amtToCreate);
    // }

    // function createAndSellOption(uint256 repoIndex, uint256 amtToBurn) public {
    //     //TODO: write this
    // }

    /* @notice: allows the owner to burn their put Tokens
    @param repoIndex: Index of the repo to burn putTokens
    @param amtToBurn: number of pTokens to burn
    @dev: only want to call this function before expiry. After expiry, 
    no benefit to calling it.
    */
    function burnPutTokens(uint256 repoIndex, uint256 amtToBurn) public {
        Repo storage repo = repos[repoIndex];
        require(repo.owner == msg.sender, "Not the owner of this repo");
        repo.putsOutstanding = repo.putsOutstanding.sub(amtToBurn);
        _burn(msg.sender, amtToBurn);
    }

    function transferRepoOwnership(uint256 repoIndex, address payable newOwner) public {
        require(repos[repoIndex].owner == msg.sender, "Cannot transferRepoOwnership as non owner");
        repos[repoIndex].owner = newOwner;
    }

    /* @notice: allows the owner to remove excess collateral from the repo before expiry. 
    @param repoIndex: Index of the repo to burn putTokens
    @param amtToRemove: Amount of collateral to remove in 10^-18. 
    */ 
    function removeCollateral(uint256 repoIndex, uint256 amtToRemove) public {

        require(now < expiry, "Can only call remove collateral before expiry");
        // check that we are well collateralized enough to remove this amount of collateral
        Repo storage repo = repos[repoIndex];
        require(msg.sender == repo.owner, "Only owner can remove collateral");
        require(amtToRemove <= repo.collateral, "Can't remove more collateral than owned");
        uint256 newRepoCollateralAmt = repo.collateral.sub(amtToRemove);

        require(isSafe(newRepoCollateralAmt, repo.putsOutstanding), "Repo is unsafe");

        repo.collateral = newRepoCollateralAmt;
        transferCollateral(msg.sender, amtToRemove);
        totalCollateral = totalCollateral.sub(amtToRemove);
    }
    /* @notice: post expiry, each repo holder can get back their proportional share of collateral 
    @dev: repo.collateral / totalCollateral * (totalCollateral - totalExercised) */
    function claimCollateral (uint256 repoIndex) public {
        // TODO: uncomment and test with expiry
        // require(now >= expiry, "Can't collect collateral until expiry");
        // pay out people proportional
        Repo storage repo = repos[repoIndex];

        require(msg.sender == repo.owner, "only owner can claim collatera");

        uint256 collateralLeft = totalCollateral.sub(totalExercised);
        uint256 collateralToTransfer = repo.collateral.mul(collateralLeft).div(totalCollateral);
        uint256 underlyingToTransfer = repo.collateral.mul(totalUnderlying).div(totalCollateral);

        repo.collateral = 0;

        emit ClaimedCollateral(collateralToTransfer, underlyingToTransfer);
        transferCollateral(msg.sender, collateralToTransfer);
        transferUnderlying(msg.sender, underlyingToTransfer);

    }

    /* @notice: checks if a repo is unsafe. If so, it can be liquidated 
    @param repoIndex: The number of the repo to check 
    @return: true or false */
    function isUnsafe(uint256 repoIndex) public returns (bool) {
        Repo storage repo = repos[repoIndex];

        bool isUnsafe = !isSafe(repo.collateral, repo.putsOutstanding);

        emit unsafeCalled(isUnsafe);

        return isUnsafe;
    }

    /* @notice: checks if a repo is unsafe. If so, it can be liquidated 
    @param repoNum: The number of the repo to check 
    @return: true or false */
    function isSafe(uint256 collateralAmt, uint256 putsOutstanding) internal returns (bool) {
        // get price from Oracle
        uint256 ethToCollateralPrice = getPrice(address(collateral));
        uint256 ethToStrikePrice = getPrice(address(strike));
  
        /* putsOutstanding * collateralizationRatio * strikePrice <= collAmt * collateralToStrikePrice 
         collateralToStrikePrice = ethToStrikePrice.div(ethToCollateralPrice);  */ 

        uint256 leftSideVal = putsOutstanding.mul(collateralizationRatio.value).mul(strikePrice.value);
        int32 leftSideExp = collateralizationRatio.exponent + strikePrice.exponent;

        uint256 rightSideVal = (collateralAmt.mul(ethToStrikePrice)).div(ethToCollateralPrice);
        int32 rightSideExp = collateralExp;

        uint32 exp = 0;
        bool isSafe = false;

        if(rightSideExp < leftSideExp) {
            exp = uint32(leftSideExp - rightSideExp);
            isSafe = leftSideVal.mul(10**exp) <= rightSideVal;
        } else {
            exp = uint32(rightSideExp - leftSideExp);
            isSafe = leftSideVal <= rightSideVal.mul(10 ** exp);
        }
        //TODO: remove after debugging.
        emit safe(leftSideVal, rightSideVal, leftSideExp, rightSideExp, isSafe);
        return isSafe;
    }

    /* Liquidator comes with _oTokens. They get _oTokens * strikePrice * (incentive + fee) 
    amount of collateral out. They can get a max of liquidationFactor * collateral out 
    in one function call. 
    */ 
    function liquidate(uint256 repoNum, uint256 _oTokens) public {
        // can only be called before the options contract expired
        require(now < expiry, "Options contract expired");

        Repo storage repo = repos[repoNum];

        // cannot liquidate a safe repo.
        require(isUnsafe(repoNum), "Repo is safe");

        // Owner can't liquidate themselves
        require(msg.sender != repo.owner, "Owner can't liquidate themselves");

        // TODO: Price oracle + decimal conversions for liqFee etc. 
        // Get price from oracle
        uint256 ethToCollateralPrice = getPrice(address(collateral));
        uint256 ethToStrikePrice = getPrice(address(strike));
 
        // calculate how much should be paid out        
        uint256 amtCollateralToPayNum = _oTokens.mul(strikePrice.value).mul(liquidationIncentive.value).mul(ethToCollateralPrice);
        int32 amtCollateralToPayExp = strikePrice.exponent + liquidationIncentive.exponent - collateralExp;
        uint256 amtCollateralToPay = 0;
        if(amtCollateralToPayExp > 0) {
            uint32 exp = uint32(amtCollateralToPayExp);
            amtCollateralToPay = amtCollateralToPayNum.mul(10 ** exp).div(ethToStrikePrice);
        } else {
            uint32 exp = uint32(-1 * amtCollateralToPayExp);
            amtCollateralToPay = (amtCollateralToPayNum.div(10 ** exp)).div(ethToStrikePrice);
        }

        // calculate our protocol fees
        // uint256 amtCollateralFeeNum = _oTokens.mul(strikePrice.value).mul(liquidationFee.value).mul(ethToCollateralPrice);
        // int32 amtCollateralFeeExp = strikePrice.exponent + liquidationFee.exponent - collateralExp;
        // if(amtCollateralToPayExp > 0) {
        //     uint32 exp = uint32(amtCollateralFeeExp);
        //     amtCollateralFeeNum = amtCollateralFeeNum.mul(10 ** exp).div(ethToStrikePrice);
        // } else {
        //     uint32 exp = uint32(-1 * amtCollateralFeeExp);
        //     amtCollateralFeeNum = (amtCollateralFeeNum.div(10 ** exp)).div(ethToStrikePrice);
        // }

        emit Liquidate(amtCollateralToPay);

        // calculate the maximum amount of collateral that can be liquidated
        uint256 maxCollateralLiquidatable = repo.collateral.mul(liquidationFactor.value);
        if(liquidationFactor.exponent > 0) {
            maxCollateralLiquidatable = maxCollateralLiquidatable.div(10 ** uint32(liquidationFactor.exponent));
        } else {
            maxCollateralLiquidatable = maxCollateralLiquidatable.div(10 ** uint32(-1 * liquidationFactor.exponent));
        }

        require(amtCollateralToPay <= maxCollateralLiquidatable, 
        "Can only liquidate liquidation factor at any given time");

        // deduct the collateral and putsOutstanding
        repo.collateral = repo.collateral.sub(amtCollateralToPay);
        repo.putsOutstanding = repo.putsOutstanding.sub(_oTokens);

        // // transfer the collateral and burn the _oTokens
         _burn(msg.sender, _oTokens);
         transferCollateral(msg.sender, amtCollateralToPay);
         // TODO: What happens to fees? 

         // TODO: emit event and return something
    }

    function transferCollateral(address payable _addr, uint256 _amt) internal {
        if (isETH(collateral)){
            msg.sender.transfer(_amt);
        } else {
            collateral.transfer(msg.sender, _amt);
        }
    }

    function transferUnderlying(address payable _addr, uint256 _amt) internal {
        if (isETH(underlying)){
            msg.sender.transfer(_amt);
        } else {
            underlying.transfer(msg.sender, _amt);
        }
    }

    function getPrice(address asset) internal view returns (uint256) {

        if(asset == address(0)) {
            return (10 ** 18);
        } else {
            return COMPOUND_ORACLE.getPrice(asset);
        }
    }

    function() external payable {
        // to get ether from uniswap exchanges
    }
}
