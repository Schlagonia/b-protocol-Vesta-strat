// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;
pragma abicoder v2;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ExtendedDSTest} from "./ExtendedDSTest.sol";
import {stdCheats} from "forge-std/stdlib.sol";
import {Vm} from "forge-std/Vm.sol";
import {IVault} from "../../interfaces/Vault.sol";
import "forge-std/console.sol";

import "../../interfaces/Chainlink/AggregatorV3Interface.sol";

// NOTE: if the name of the strat or file changes this needs to be updated
import {Strategy} from "../../Strategy.sol";

// Artifact paths for deploying from the deps folder, assumes that the command is run from
// the project root.
string constant vaultArtifact = "artifacts/Vault.json";

// Base fixture deploying Vault
contract StrategyFixture is ExtendedDSTest, stdCheats {
    using SafeERC20 for IERC20;

    // we use custom names that are unlikely to cause collisions so this contract
    // can be inherited easily
    // TODO: see if theres a better way to use this
    Vm public constant vm_std_cheats =
        Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    IVault public vault;
    Strategy public strategy;
    IERC20 public weth;
    IERC20 public want;

    // NOTE: feel free change these vars to adjust for your strategy testing
    IERC20 public constant DAI =
        IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 public constant WETH =
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 public constant LUSD =
        IERC20(0x5f98805A4E8be255a32880FDeC7F6728C6568bA0);
    IERC20 public constant LQTY = 
        IERC20(0x6DEA81C8171D0bA574754EF6F8b412F2Ed88c54D);

    address public constant bProtocolPool = 0x00FF66AB8699AAfa050EE5EF5041D1503aa0849a;
    
    address public whale = 0x5f98805A4E8be255a32880FDeC7F6728C6568bA0; // OlympusDAO treasury
    address public user = address(1337);
    address public strategist = address(1);
    uint256 public constant WETH_AMT = 10**18;

    uint256 internal constant ONE_BIP_REL_DELTA = 10000;
    uint256 internal constant ONE_MINUTE = 60;

    function setUp() public virtual {
        weth = WETH;

        // replace with your token
        want = LUSD;

        deployVaultAndStrategy(
            address(want),
            address(this),
            address(this),
            "",
            "",
            address(this),
            address(this),
            address(this),
            strategist
        );

        // do here additional setup
        vm_std_cheats.label(address(vault), "Vault");
        vm_std_cheats.label(address(strategy), "Strategy");
        vm_std_cheats.label(address(DAI), "DAI");
        vm_std_cheats.label(address(WETH), "WETH");
        vm_std_cheats.label(address(want), "Want");
        vm_std_cheats.label(address(LQTY), "LQTY");
        vm_std_cheats.label(bProtocolPool, "B.Protocol");
        vm_std_cheats.label(address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419), "ChainlinkETHUSD");
        vm_std_cheats.label(address(0x66017D22b0f8556afDd19FC67041899Eb65a21bb), "Liquity");
        vm_std_cheats.label(address(0xEd279fDD11cA84bEef15AF5D39BB4d4bEE23F0cA), "CurvePool");
        vm_std_cheats.label(address(0xE592427A0AEce92De3Edee1F18E0157C05861564), "Uniswap");
        vault.setDepositLimit(type(uint256).max);
        tip(address(want), address(user), 100_000_000 ether);
        vm_std_cheats.deal(user, 10_000 ether);

        testSetupVaultOK();
        testSetupStrategyOK();
    }

    // Deploys a vault
    function deployVault(
        address _token,
        address _gov,
        address _rewards,
        string memory _name,
        string memory _symbol,
        address _guardian,
        address _management
    ) public returns (address) {
        address _vault = deployCode(vaultArtifact);
        vault = IVault(_vault);

        vault.initialize(
            _token,
            _gov,
            _rewards,
            _name,
            _symbol,
            _guardian,
            _management
        );

        return address(vault);
    }

    // Deploys a strategy
    function deployStrategy(address _vault) public returns (address) {
        Strategy _strategy = new Strategy(_vault);

        return address(_strategy);
    }

    // Deploys a vault and strategy attached to vault
    function deployVaultAndStrategy(
        address _token,
        address _gov,
        address _rewards,
        string memory _name,
        string memory _symbol,
        address _guardian,
        address _management,
        address _keeper,
        address _strategist
    ) public returns (address _vault, address _strategy) {
        _vault = deployCode(vaultArtifact);
        vault = IVault(_vault);

        vault.initialize(
            _token,
            _gov,
            _rewards,
            _name,
            _symbol,
            _guardian,
            _management
        );

        vm_std_cheats.prank(_strategist);
        _strategy = deployStrategy(_vault);
        strategy = Strategy(payable(_strategy));

        vm_std_cheats.prank(_strategist);
        strategy.setKeeper(_keeper);

        vault.addStrategy(_strategy, 10_000, 0, type(uint256).max, 1_000);
    }

    function testSetupVaultOK() internal {
        console.log("address of vault", address(vault));
        assertTrue(address(0) != address(vault));
        assertEq(vault.token(), address(want));
        assertEq(vault.depositLimit(), type(uint256).max);
    }

    // TODO: add additional check on strat params
    function testSetupStrategyOK() internal {
        console.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(address(strategy.vault()), address(vault));
    }

    function depositToVault(address _depositor, IVault _vault, uint256 _amount) internal {
        uint256 _vaultWantBalanceBefore = want.balanceOf(address(vault));

        vm_std_cheats.prank(_depositor);
        want.approve(address(_vault), _amount);
        vm_std_cheats.prank(_depositor);
        vault.deposit(_amount);

        assertEq(want.balanceOf(address(vault)), _amount + _vaultWantBalanceBefore);
    }

    function mockChainlink() internal {
        AggregatorV3Interface chainlink = AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419); // ETH/USD oracle that B.Protcol calls
        (
            uint80 _roundId,
            int256 _answer,
            ,
            ,
            uint80 _answeredInRound
        ) = chainlink.latestRoundData();

        vm_std_cheats.mockCall(address(chainlink), abi.encodeWithSelector(chainlink.latestRoundData.selector), abi.encode(_roundId, _answer, block.timestamp + 1000000, block.timestamp + 1000000, _answeredInRound));
    }
}
