// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.6.0 <0.7.0;
pragma experimental ABIEncoderV2;


import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "https://github.com/yearn/yearn-protocol/blob/develop/interfaces/yearn/IController.sol";

//interface of Yearn dummy Vault
interface VaultAPI is IERC20 {

    /**
     * View how much the Vault would like to pull back from the Strategy,
     * based on its present performance (since its last report). Can be used to
     * determine expectedReturn in your Strategy.
     */
    function debtOutstanding() external view returns (uint256);
    function deposit(uint256) external;
    function get_vault_price() external view returns (uint256); //function to get current price of token in vault
    function withdraw(uint256) external;
}
  
/**
 * This interface is here for the keeper bot to use.

 */
interface StrategyAPI {
    
    function tendTrigger(uint256 callCost) external view returns (bool);
    function tend() external;
    function harvestTrigger(uint256 callCost) external view returns (bool);
    function harvest() external;
    event Harvested(uint256 profit, uint256 loss, uint256 debtPayment, uint256 debtOutstanding);
}

/**
 * P Protocol interface
*/
interface IPool {
    //function to add liquidity to P pool
    function add_liquidity(

        uint256 amounts,
        uint256 min_mint_amount
    ) external; 

    function get_price() external view returns (uint256); //function to get current price of token to be deposited in pool
    function stake() external view returns (uint256); //function to stake Y Token 
    function remove_liquidity(uint256 _amount) external; //remove liquidity from P pool   
}


abstract contract BaseStrategy{

    function ethToWant(uint256 _amtInWei) public virtual view returns (uint256);
    function adjustPosition(uint256 _debtOutstanding) internal virtual;

    /**
     * @notice
     *  Provide a signal to the keeper that `tend()` should be called. The
     *  keeper will provide the estimated gas cost that they would pay to call
     *  `tend()`, and this function should use that estimate to make a
     *  determination if calling it is "worth it" for the keeper 
     */
    function tendTrigger(uint256 callCostInWei) public virtual view returns (bool) {
        // We usually don't need tend, but if there are positions that need
        // active maintainence, overriding this function is how you would
        // signal for that.
        uint256 callCost = ethToWant(callCostInWei);
        return false;
    }

    modifier onlyKeepers() {
        require(
            msg.sender == keeper ||
                msg.sender == strategist ||
                msg.sender == governance() ||
                msg.sender == vault.guardian() ||
                msg.sender == vault.management(),
            "!authorized"
        );
        _;
    }
}

 /**
     * @notice
     * ApeStrategy to work with Yearn Vault.The strategy provides liquidity to protocol P, 
     * receiving yield(Y token) and R reward, then reinvests income received in P at a regular basis in order to secure higher yield.
     * reinvesting occurs by staking the Y token into P protocol's `Pstakepool` pool.
*/

contract ApeStrategy is BaseStrategy,VaultAPI,StrategyAPI,IPool{
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address public constant want = address(Deposit_Token_Address);
    address public constant Ppool = address(P_Protocol_Address);
    address public constant PstakePool = address(P_Protocol_Staking_Address);
    address public constant Ytoken = address(Yield_Token_Address);
    address public constant Rtoken = address(Reward_Token_Address);
    address public constant Vault = address(Vault_Address);

    //strategy parameters
    uint256 public performanceFee = 500;
    uint256 public constant performanceMax = 10000;
    uint256 public tank = 0; 
    uint256 public slip = 5; //slipage parameter
    uint256 public constant DENOMINATOR = 10000;
    uint256 public withdrawalFee = 50;
    uint256 public constant withdrawalMax = 10000;
    uint256 public treasuryFee = 1000;

    address public governance;
    address public controller;
    address public strategist;
    address public keeper;
    VaultAPI public vault;

 constructor(address _controller) public {
        governance = msg.sender;
        strategist = msg.sender;
        keeper = msg.sender;
        controller = _controller;
    }

    function getName() external pure returns (string memory) {
        return "ApeStrategy";
    }

    function setStrategist(address _strategist) external {
        require(msg.sender == governance, "!governance");
        strategist = _strategist;
    }

    function setWithdrawalFee(uint256 _withdrawalFee) external {
        require(msg.sender == governance, "!governance");
        withdrawalFee = _withdrawalFee;
    }
    
    function setPerformanceFee(uint256 _performanceFee) external {
        require(msg.sender == governance, "!governance");
        performanceFee = _performanceFee;
    }

    function setController(address _controller) external {
        require(msg.sender == governance, "!governance");
        controller = _controller;
    }

    /**
      * @notice
      * add liquidity to P protocol pool and deposit reward token Rtoken to vault
    */
    function harvest() public onlyKeepers{

        rebalance();
        uint256 _want = (IERC20(want).balanceOf(address(this))).sub(tank);
        if (_want > 0) {
            if (_want > maxAmount) _want = maxAmount;
            IERC20(want).safeApprove(Ppool, 0);
            IERC20(want).safeApprove(Ppool, _want);
            uint256 v = _want.mul(1e18).div(IPool(Ppool).get_price());
            IPool(Ppool).add_liquidity(_want, v.mul(DENOMINATOR.sub(slip)).div(DENOMINATOR)); //add liquidity to P protocol
        }

        uint256 _Rtoken = IERC20(Rtoken).balanceOf(address(this));
        if (_Rtoken > 0) {
            IERC20(Rtoken).safeApprove(Vault, 0);
            IERC20(Rtoken).safeApprove(Vault, _Rtoken);
            VaultAPI(Vault).deposit(_Rtoken); //deposit reward token to vault
        }      
    }

    /**
     * @notice
     *  Provide a signal to the keeper that `tend()` should be called. The
     *  keeper will provide the estimated gas cost that they would pay to call
     *  `tend()`, and this function should use that estimate to make a
     *  determination if calling it is "worth it" for the keeper 
     */
    function tendTrigger(uint256 callCostInWei) public override virtual view returns (bool) {
        // We usually don't need tend, but if there are positions that need
        // active maintainence, overriding this function is how you would
        // signal for that.
        uint256 callCost = ethToWant(callCostInWei);
        return false;
    }

    /**
     * @notice
     * reinvest yield Ytoken by staking it in P protocol's Pstake pool 
    */
    function tend() external override onlyKeepers {

        uint256 callCostInWei;
        require (tendTrigger(callCostInWei) == true && harvestTrigger(callCostInWei) == false,"cost of execution too high!");

        // Don't take profits with this call, but adjust for better gains

        adjustPosition(vault.debtOutstanding());

        uint256 _Ytoken = IERC20(Ytoken).balanceOf(address(this));
        if (_Ytoken > 0) {
            IERC20(Ytoken).safeApprove(PstakePool, 0);
            IERC20(Ytoken).safeApprove(PstakePool, _Ytoken);
            IPool(PstakePool).stake(_Ytoken); //stake Ytoken in Pstake pool for more rewards.
        }
    }

    // Controller only function for creating additional rewards from dust
    function withdraw(IERC20 _asset) external returns (uint256 balance) {
        require(msg.sender == controller, "!controller");
        require(want != address(_asset), "want");
        require(Ytoken != address(_asset), "Ytoken");
        require(Vault != address(_asset), "Vault");
        balance = _asset.balanceOf(address(this));
        _asset.safeTransfer(controller, balance);
    }

    // Withdraw partial funds, normally used with a vault withdrawal
    function withdraw(uint256 _amount) external {
        require(msg.sender == controller, "!controller");

        rebalance();
        uint256 _balance = IERC20(want).balanceOf(address(this));
        if (_balance < _amount) {
            _amount = _withdrawSome(_amount.sub(_balance));
            _amount = _amount.add(_balance);
            tank = 0;
        } else {
            if (tank >= _amount) tank = tank.sub(_amount);
            else tank = 0;
        }

        address _vault = IController(controller).vaults(address(want));
        require(_vault != address(0), "!vault"); // additional protection so we don't burn the funds
        uint256 _fee = _amount.mul(withdrawalFee).div(DENOMINATOR);
        IERC20(want).safeTransfer(IController(controller).rewards(), _fee);
        IERC20(want).safeTransfer(_vault, _amount.sub(_fee));
    }

    function _withdrawSome(uint256 _amount) internal returns (uint256) {
        uint256 _amnt = _amount.mul(1e18).div(IPool(Ppool).get_price());
        uint256 _amt = _amnt.mul(1e18).div(VaultApi(Vault).get_vault_price());
        uint256 _before = IERC20(Ytoken).balanceOf(address(this));
        VaultApi(Vault).withdraw(_amt);
        uint256 _after = IERC20(Ytoken).balanceOf(address(this));
        return _withdrawOne(_after.sub(_before));
    }

    function _withdrawOne(uint256 _amnt) internal returns (uint256) {
        uint256 _before = IERC20(want).balanceOf(address(this));
        IERC20(Ytoken).safeApprove(Ppool, 0);
        IERC20(Ytoken).safeApprove(Ppool, _amnt);
        IPool(Ppool).remove_liquidity(_amnt);
        uint256 _after = IERC20(want).balanceOf(address(this));

        return _after.sub(_before);
    }

    // Withdraw all funds, normally used when migrating strategies
    function withdrawAll() external returns (uint256 balance) {
        require(msg.sender == controller, "!controller");
        _withdrawAll();

        balance = IERC20(want).balanceOf(address(this));

        address _vault = IController(controller).vaults(address(want));
        require(_vault != address(0), "!vault"); // additional protection so we don't burn the funds
        IERC20(want).safeTransfer(_vault, balance);
    }

    function _withdrawAll() internal {
        uint256 _vault = IERC20(Vault).balanceOf(address(this));
        if (_vault > 0) {
            VaultAPI(Vault).withdraw(_vault);
            _withdrawOne(IERC20(Ytoken).balanceOf(address(this))); 
        }
    }

    //View functions
    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    function balanceOfYtoken() public view returns (uint256) {
        return IERC20(Ytoken).balanceOf(address(this));
    }

    function balanceOfYtokeninWant() public view returns (uint256) {
        return balanceOfYtoken().mul(IPool(Pppool).get_price()).div(1e18);
    }

    function balanceOfVault() public view returns (uint256) {
        return IERC20(Vault).balanceOf(address(this));
    }

    function balanceOfYtokeninYtoken() public view returns (uint256) {
        return balanceOfYtoken().mul(VaultAPI(Vault).get_vault_price()).div(1e18);
    }

    function balanceOfYtokeninWant() public view returns (uint256) {
        return balanceOfYtokeninYtoken().mul(IPool(_3pool).get_price()).div(1e18);
    }

    function balanceOf() public view returns (uint256) {
        return balanceOfWant().add(balanceOfYtokeninWant());
    }

    //migrate to a new strategy
    function migrate(address _strategy) external {
        require(msg.sender == governance, "!governance");
        require(IController(controller).approvedStrategies(want, _strategy), "!stategyAllowed");
        IERC20(Vault).safeTransfer(_strategy, IERC20(Vault).balanceOf(address(this)));
        IERC20(Ytoken).safeTransfer(_strategy, IERC20(Ytoken).balanceOf(address(this)));
        IERC20(want).safeTransfer(_strategy, IERC20(want).balanceOf(address(this)));
    }

    //drip() used in rebalance() to rebalance the vault
    function drip() public onlyKeepers {
        uint256 _p = VaultAPI(Vault).get_vault_price();
        _p = _p.mul(IPool(Ppool).get_price()).div(1e18);
        require(_p >= p, "backward");
        uint256 _r = (_p.sub(p)).mul(balanceOfYtoken()).div(1e18);
        uint256 _s = _r.mul(strategistReward).div(DENOMINATOR);
        IERC20(Vault).safeTransfer(strategist, _s.mul(1e18).div(_p));
        uint256 _t = _r.mul(treasuryFee).div(DENOMINATOR);
        IERC20(Vault).safeTransfer(IController(controller).rewards(), _t.mul(1e18).div(_p));
        p = _p;
    }

    function tick() public view returns (uint256 _t, uint256 _c) {
        _t = IPool(Ppool).balances(0).mul(threshold).div(DENOMINATOR);
        _c = balanceOfYtokeninWant();
    }

    //rebalance 
    function rebalance() public onlyKeepers{
        drip();
        (uint256 _t, uint256 _c) = tick();
        if (_c > _t) {
            _withdrawSome(_c.sub(_t));
            tank = IERC20(want).balanceOf(address(this));
        }
    }

    //overidden functions
    function ethToWant(uint256 _amtInWei) public override virtual view returns (uint256){}
    function adjustPosition(uint256 _debtOutstanding) internal override virtual{}
    function debtOutstanding() public override view returns (uint256){}
    function deposit(uint256) public override{}
    function add_liquidity(uint256 amounts,uint256 min_mint_amount) public override onlyKeepers{}
    function harvestTrigger(uint256 callCost) public override view onlyKeepers returns (bool){}
    function harvest() public override onlyKeepers{ event Harvested(profit,loss,debtPayment,debtOutstanding);}
    function stake() public override view onlyKeepers returns (uint256){}
    function get_price() public override view returns (uint256){}
    function get_vault_price() public override view returns (uint256){}
    function withdraw(uint256) public override{}
    function remove_liquidity(uint256 _amount) public override{} 

    
}
