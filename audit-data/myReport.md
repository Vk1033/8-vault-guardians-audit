## Issues Found

| Severity | Number of issues found |
| -------- | ---------------------- |
| High     | 5                      |
| Medium   | 0                      |
| Low      | 10                     |
| Info     | 1                      |
| Gas      | 2                      |
| Total    | 18                     |

# High Issues

### [H-1] Potential Token Steal (Due to no access control)

**Description:**
In src/protocol/VaultGuardians.sol:sweepErc20s function, the lack of access control allows anyone to call and transfer balance to owner making protocol unusable

```solidity
function sweepErc20s(IERC20 asset) external {
        uint256 amount = asset.balanceOf(address(this));
        emit VaultGuardians__SweptTokens(address(asset));
        asset.safeTransfer(owner(), amount);
    }
```

**Poc**
This test shows that even, a normal user can call sweepErc20s function to take out funds to DAO, and make protocol unusable

```solidity
function testSweepErc20sbyAnyone() public {
        ERC20Mock mock = new ERC20Mock();
        mock.mint(mintAmount, msg.sender);
        vm.prank(msg.sender);
        mock.transfer(address(vaultGuardians), mintAmount);

        uint256 balanceBefore = mock.balanceOf(address(vaultGuardianGovernor));

        vm.prank(user);
        vaultGuardians.sweepErc20s(IERC20(mock));

        uint256 balanceAfter = mock.balanceOf(address(vaultGuardianGovernor));

        assertEq(balanceAfter - balanceBefore, mintAmount);
    }
```

**Recommended Mitigation:**

```diff
-   function sweepErc20s(IERC20 asset) external {
+   function sweepErc20s(IERC20 asset) external onlyOwner {
        uint256 amount = asset.balanceOf(address(this));
        emit VaultGuardians__SweptTokens(address(asset));
        asset.safeTransfer(owner(), amount);
    }
```

### [H-2] Deposit by user in a vault, breaks the invariant by minitng fee shares to both user and DaO and guardian

**Description:**
Deposit by user in a vault, breaks the invariant by minting fee shares to both user and DAO and guardian

```solidity
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IERC4626)
        isActive
        nonReentrant
        returns (uint256)
    {
        if (assets > maxDeposit(receiver)) {
            revert VaultShares__DepositMoreThanMax(assets, maxDeposit(receiver));
        }

        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);

@>      _mint(i_guardian, shares / i_guardianAndDaoCut);
@>      _mint(i_vaultGuardians, shares / i_guardianAndDaoCut);

        _investFunds(assets);
        return shares;
    }
```

**Impact:**
Breaking the invariant makes the main function of protocol invalid and also accumulating extra shares which do not exist in deposits

**Proof of Concept:**

Test

```solidity
    function testDepositMintsMoreThanPreviewDeposit() public hasGuardian {
        weth.mint(mintAmount, user);
        vm.startPrank(user);

        weth.approve(address(wethVaultShares), mintAmount);

        // previewDeposit should tell us how many shares will be minted for user
        uint256 previewShares = wethVaultShares.previewDeposit(mintAmount);

        uint256 supplyBefore = wethVaultShares.totalSupply();
        wethVaultShares.deposit(mintAmount, user);
        uint256 supplyAfter = wethVaultShares.totalSupply();

        uint256 actualMinted = supplyAfter - supplyBefore;

        emit log_named_uint("previewDepositShares", previewShares);
        emit log_named_uint("actualMintedShares", actualMinted);
        emit log_named_uint("difference", actualMinted - previewShares);
        emit log_named_uint("daoAndGuardianShares", actualMinted / defaultGuardianAndDaoCut * 2);
        emit log_named_uint("expectedDaoAndGuardianShares", previewShares / defaultGuardianAndDaoCut * 2);

        // ✅ Show the bug: more shares are minted than previewDeposit predicts
        assertGt(actualMinted, previewShares);
    }
```

**Recommended Mitigation:**

```diff
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626, IERC4626)
        isActive
        nonReentrant
        returns (uint256)
    {
        if (assets > maxDeposit(receiver)) {
            revert VaultShares__DepositMoreThanMax(assets, maxDeposit(receiver));
        }

+        uint256 totalShares = previewDeposit(assets);
+        uint256 fee = totalShares / i_guardianAndDaoCut; // or however you want to split
+        uint256 userShares = totalShares - 2 * fee; // net after fees

+        _deposit(_msgSender(), receiver, assets, userShares);

+        _mint(i_guardian, fee);
+        _mint(i_vaultGuardians, fee);

-        uint256 shares = previewDeposit(assets);
-        _deposit(_msgSender(), receiver, assets, shares);

-        //a shouldn't DAO and guardian shares be subtracted? from receiver's shares? exactly, it's a medium
-        _mint(i_guardian, shares / i_guardianAndDaoCut);
-        _mint(i_vaultGuardians, shares / i_guardianAndDaoCut);

        _investFunds(assets);
        return shares;
    }

```

### [H-3] Incorrect Liquidity Input Calculation in `_uniswapInvest` (Misuse of `amounts[0]` → Double Counting Input Tokens)

**Description:**  
In `_uniswapInvest`, the contract calls `swapExactTokensForTokens` to swap half of the input tokens.  
The router returns an array `amounts`, where `amounts[0]` is simply the input amount (`amountOfTokenToSwap`) and `amounts[1]` is the output received.

However, when providing liquidity, the contract sets:

```solidity
amountADesired: amountOfTokenToSwap + amounts[0],
```

Since `amounts[0] == amountOfTokenToSwap`, this expression equals `2 * amountOfTokenToSwap`.  
The vault does **not** actually have this many tokens available because `amountOfTokenToSwap` was already spent during the swap.  
As a result, the function attempts to supply more tokens than are available, leading to failure or suboptimal liquidity provision.

---

**Impact:**

- Liquidity addition may revert due to insufficient token balance.
- If it does not revert (e.g., with non-standard tokens), liquidity provision parameters may become inconsistent, reducing capital efficiency and causing misaccounting of funds.
- The vault cannot reliably invest user funds as intended, which could block deposits or result in underutilized capital.

---

**Proof of Concept:**

1. Assume `amount = 1000` tokens.
2. `amountOfTokenToSwap = 500`.
3. Swap executes, sending `500` tokens and receiving `X` counterparty tokens.
4. After swap, the vault has only **500 remaining tokens**, not `1000`.
5. Contract sets `amountADesired = 500 + 500 = 1000`.
6. Router tries to pull `1000` tokens for liquidity, but only `500` are available → revert.

---

**Recommended Mitigation:**  
Use the correct remaining token balance after swap instead of `amountOfTokenToSwap + amounts[0]`.  
This can be done by:

```diff
(uint256 tokenAmount, uint256 counterPartyTokenAmount, uint256 liquidity) =
    i_uniswapRouter.addLiquidity({
        tokenA: address(token),
        tokenB: address(counterPartyToken),
-       amountADesired: amountOfTokenToSwap + amounts[0],
+       amountADesired: amounts[0],
        amountBDesired: amounts[1],
        amountAMin: minA,
        amountBMin: minB,
        to: address(this),
        deadline: block.timestamp + 300
    });
```

This ensures that the contract only supplies what it actually holds, preventing reverts and ensuring accurate liquidity addition.

### [H-4] Unbounded Slippage Parameters (`amountOutMin = 0`, `amountAMin = 0`, `amountBMin = 0`)

**Description:**  
Both `_uniswapInvest` and `_uniswapDivest` use Uniswap functions with all slippage-related parameters set to `0`.  
This disables any protection against unfavorable execution prices, making swaps and liquidity operations highly vulnerable to sandwich and MEV attacks.

**Occurrences:**

- `_uniswapInvest` → `swapExactTokensForTokens`:

```solidity
amountOutMin: 0,
```

- `_uniswapInvest` → `addLiquidity`:

```solidity
amountAMin: 0,
amountBMin: 0,
```

- `_uniswapDivest` → `removeLiquidity`:

```solidity
amountAMin: 0,
amountBMin: 0,
```

- `_uniswapDivest` → `swapExactTokensForTokens`:

```solidity
amountOutMin: 0,
```

---

**Impact:**

- The vault can lose significant funds due to sandwich attacks or extreme price movements.
- Users depositing to the vault may face large losses without any transaction reverting.
- No protection exists against executing trades at unfavorable rates.

---

**Proof of Concept:**

- An attacker observes a vault calling `_uniswapInvest`.
- The attacker front-runs the swap, moves the price against the vault, then back-runs to restore price.
- Because `amountOutMin = 0`, the vault accepts the poor execution, losing value to the attacker.

---

**Recommended Mitigation:**  
Introduce slippage protection by setting `amountOutMin`, `amountAMin`, and `amountBMin` based on expected output with a tolerance. For example, if slippage tolerance is `50 bps (0.5%)`:

```solidity
uint256 minOut = expectedOut * 995 / 1000; // 0.5% tolerance
i_uniswapRouter.swapExactTokensForTokens({
    amountIn: amountOfTokenToSwap,
    amountOutMin: minOut,
    path: path,
    to: address(this),
    deadline: block.timestamp + 300
});
```

Apply similar checks for `amountAMin` and `amountBMin` in `addLiquidity` and `removeLiquidity`.

---

### [H-5] Fragile Deadlines (`deadline = block.timestamp`)

**Description:**  
The contract sets Uniswap deadlines to `block.timestamp`. This provides no buffer for miners, network delays, or user latency. In practice, transactions may fail unnecessarily, or miners could slightly manipulate timestamps within consensus rules to influence execution.

**Occurrences:**

- `_uniswapInvest` → `swapExactTokensForTokens`:

```solidity
deadline: block.timestamp
```

- `_uniswapInvest` → `addLiquidity`:

```solidity
deadline: block.timestamp
```

- `_uniswapDivest` → `removeLiquidity`:

```solidity
deadline: block.timestamp
```

- `_uniswapDivest` → `swapExactTokensForTokens`:

```solidity
deadline: block.timestamp
```

---

**Impact:**

- Transactions may revert frequently if not included in the same block they are submitted.
- Miners/validators have minor ability to manipulate timestamps to affect whether a transaction is valid.
- Users and vault logic may experience reliability issues when interacting with Uniswap.

---

**Proof of Concept:**

- A transaction using `_uniswapInvest` is broadcast but not included in the current block.
- By the next block, `block.timestamp` has advanced, making the `deadline` invalid.
- The transaction reverts even though conditions are otherwise acceptable.

---

**Recommended Mitigation:**  
Set a reasonable deadline window instead of `block.timestamp`. For example:

```solidity
uint256 deadline = block.timestamp + 300; // 5 minutes buffer
```

Make the buffer configurable so operators can tune it for different environments.

# Low Issues

## L-1: Centralization Risk

Contracts have owners with privileged rights to perform admin tasks and need to be trusted to not perform malicious updates or drain funds.

<details><summary>5 Found Instances</summary>

- Found in src/dao/VaultGuardianToken.sol [Line: 11](src/dao/VaultGuardianToken.sol#L11)

  ```solidity
  contract VaultGuardianToken is ERC20, ERC20Permit, ERC20Votes, Ownable {
  ```

- Found in src/dao/VaultGuardianToken.sol [Line: 23](src/dao/VaultGuardianToken.sol#L23)

  ```solidity
      function mint(address to, uint256 amount) external onlyOwner {
  ```

- Found in src/protocol/VaultGuardians.sol [Line: 40](src/protocol/VaultGuardians.sol#L40)

  ```solidity
  contract VaultGuardians is Ownable, VaultGuardiansBase {
  ```

- Found in src/protocol/VaultGuardians.sol [Line: 73](src/protocol/VaultGuardians.sol#L73)

  ```solidity
      function updateGuardianStakePrice(uint256 newStakePrice) external onlyOwner {
  ```

- Found in src/protocol/VaultGuardians.sol [Line: 85](src/protocol/VaultGuardians.sol#L85)

  ```solidity
      function updateGuardianAndDaoCut(uint256 newCut) external onlyOwner {
  ```

</details>

## L-2: Unsafe ERC20 Operation

ERC20 functions may not behave as expected. For example: return values are not always meaningful. It is recommended to use OpenZeppelin's SafeERC20 library.

<details><summary>5 Found Instances</summary>

- Found in src/protocol/VaultGuardiansBase.sol [Line: 277](src/protocol/VaultGuardiansBase.sol#L277)

  ```solidity
          bool succ = token.approve(address(tokenVault), s_guardianStakePrice);
  ```

- Found in src/protocol/investableUniverseAdapters/AaveAdapter.sol [Line: 25](src/protocol/investableUniverseAdapters/AaveAdapter.sol#L25)

  ```solidity
          bool succ = asset.approve(address(i_aavePool), amount);
  ```

- Found in src/protocol/investableUniverseAdapters/UniswapAdapter.sol [Line: 50](src/protocol/investableUniverseAdapters/UniswapAdapter.sol#L50)

  ```solidity
          bool succ = token.approve(address(i_uniswapRouter), amountOfTokenToSwap);
  ```

- Found in src/protocol/investableUniverseAdapters/UniswapAdapter.sol [Line: 62](src/protocol/investableUniverseAdapters/UniswapAdapter.sol#L62)

  ```solidity
          succ = counterPartyToken.approve(address(i_uniswapRouter), amounts[1]);
  ```

- Found in src/protocol/investableUniverseAdapters/UniswapAdapter.sol [Line: 66](src/protocol/investableUniverseAdapters/UniswapAdapter.sol#L66)

  ```solidity
          succ = token.approve(address(i_uniswapRouter), amountOfTokenToSwap + amounts[0]);
  ```

</details>

## L-3: Address State Variable Set Without Checks

Check for `address(0)` when assigning values to address state variables.

<details><summary>1 Found Instances</summary>

- Found in src/protocol/VaultGuardiansBase.sol [Line: 273](src/protocol/VaultGuardiansBase.sol#L273)

  ```solidity
          s_guardians[msg.sender][token] = IVaultShares(address(tokenVault));
  ```

</details>

## L-4: `nonReentrant` is Not the First Modifier

To protect against reentrancy in other modifiers, the `nonReentrant` modifier should be the first modifier in the list of modifiers.

<details><summary>4 Found Instances</summary>

- Found in src/protocol/VaultShares.sol [Line: 147](src/protocol/VaultShares.sol#L147)

  ```solidity
          nonReentrant
  ```

- Found in src/protocol/VaultShares.sol [Line: 185](src/protocol/VaultShares.sol#L185)

  ```solidity
      function rebalanceFunds() public isActive divestThenInvest nonReentrant {}
  ```

- Found in src/protocol/VaultShares.sol [Line: 198](src/protocol/VaultShares.sol#L198)

  ```solidity
          nonReentrant
  ```

- Found in src/protocol/VaultShares.sol [Line: 215](src/protocol/VaultShares.sol#L215)

  ```solidity
          nonReentrant
  ```

</details>

## L-5: PUSH0 Opcode

Solc compiler version 0.8.20 switches the default target EVM version to Shanghai, which means that the generated bytecode will include PUSH0 opcodes. Be sure to select the appropriate EVM version in case you intend to deploy on a chain other than mainnet like L2 chains that may not support PUSH0, otherwise deployment of your contracts will fail.

<details><summary>18 Found Instances</summary>

- Found in src/abstract/AStaticTokenData.sol [Line: 2](src/abstract/AStaticTokenData.sol#L2)

  ```solidity
  pragma solidity 0.8.20;
  ```

- Found in src/abstract/AStaticUSDCData.sol [Line: 2](src/abstract/AStaticUSDCData.sol#L2)

  ```solidity
  pragma solidity 0.8.20;
  ```

- Found in src/abstract/AStaticWethData.sol [Line: 2](src/abstract/AStaticWethData.sol#L2)

  ```solidity
  pragma solidity 0.8.20;
  ```

- Found in src/dao/VaultGuardianGovernor.sol [Line: 2](src/dao/VaultGuardianGovernor.sol#L2)

  ```solidity
  pragma solidity 0.8.20;
  ```

- Found in src/dao/VaultGuardianToken.sol [Line: 2](src/dao/VaultGuardianToken.sol#L2)

  ```solidity
  pragma solidity 0.8.20;
  ```

- Found in src/interfaces/IVaultData.sol [Line: 2](src/interfaces/IVaultData.sol#L2)

  ```solidity
  pragma solidity 0.8.20;
  ```

- Found in src/interfaces/IVaultGuardians.sol [Line: 2](src/interfaces/IVaultGuardians.sol#L2)

  ```solidity
  pragma solidity 0.8.20;
  ```

- Found in src/interfaces/IVaultShares.sol [Line: 2](src/interfaces/IVaultShares.sol#L2)

  ```solidity
  pragma solidity 0.8.20;
  ```

- Found in src/interfaces/InvestableUniverseAdapter.sol [Line: 2](src/interfaces/InvestableUniverseAdapter.sol#L2)

  ```solidity
  pragma solidity 0.8.20;
  ```

- Found in src/protocol/VaultGuardians.sol [Line: 28](src/protocol/VaultGuardians.sol#L28)

  ```solidity
  pragma solidity 0.8.20;
  ```

- Found in src/protocol/VaultGuardiansBase.sol [Line: 28](src/protocol/VaultGuardiansBase.sol#L28)

  ```solidity
  pragma solidity 0.8.20;
  ```

- Found in src/protocol/VaultShares.sol [Line: 2](src/protocol/VaultShares.sol#L2)

  ```solidity
  pragma solidity 0.8.20;
  ```

- Found in src/protocol/investableUniverseAdapters/AaveAdapter.sol [Line: 2](src/protocol/investableUniverseAdapters/AaveAdapter.sol#L2)

  ```solidity
  pragma solidity 0.8.20;
  ```

- Found in src/protocol/investableUniverseAdapters/UniswapAdapter.sol [Line: 2](src/protocol/investableUniverseAdapters/UniswapAdapter.sol#L2)

  ```solidity
  pragma solidity 0.8.20;
  ```

- Found in src/vendor/DataTypes.sol [Line: 2](src/vendor/DataTypes.sol#L2)

  ```solidity
  pragma solidity 0.8.20;
  ```

- Found in src/vendor/IPool.sol [Line: 2](src/vendor/IPool.sol#L2)

  ```solidity
  pragma solidity 0.8.20;
  ```

- Found in src/vendor/IUniswapV2Factory.sol [Line: 3](src/vendor/IUniswapV2Factory.sol#L3)

  ```solidity
  pragma solidity 0.8.20;
  ```

- Found in src/vendor/IUniswapV2Router01.sol [Line: 2](src/vendor/IUniswapV2Router01.sol#L2)

  ```solidity
  pragma solidity 0.8.20;
  ```

</details>

## L-6: Unused Error

Consider using or removing the unused error.

<details><summary>4 Found Instances</summary>

- Found in src/protocol/VaultGuardians.sol [Line: 43](src/protocol/VaultGuardians.sol#L43)

  ```solidity
      error VaultGuardians__TransferFailed();
  ```

- Found in src/protocol/VaultGuardiansBase.sol [Line: 46](src/protocol/VaultGuardiansBase.sol#L46)

  ```solidity
      error VaultGuardiansBase__NotEnoughWeth(uint256 amount, uint256 amountNeeded);
  ```

- Found in src/protocol/VaultGuardiansBase.sol [Line: 48](src/protocol/VaultGuardiansBase.sol#L48)

  ```solidity
      error VaultGuardiansBase__CantQuitGuardianWithNonWethVaults(address guardianAddress);
  ```

- Found in src/protocol/VaultGuardiansBase.sol [Line: 51](src/protocol/VaultGuardiansBase.sol#L51)

  ```solidity
      error VaultGuardiansBase__FeeTooSmall(uint256 fee, uint256 requiredFee);
  ```

</details>

## L-7: Unused State Variable

State variable appears to be unused. No analysis has been performed to see if any inline assembly references it. Consider removing this unused variable.

<details><summary>1 Found Instances</summary>

- Found in src/protocol/VaultGuardiansBase.sol [Line: 65](src/protocol/VaultGuardiansBase.sol#L65)

  ```solidity
      uint256 private constant GUARDIAN_FEE = 0.1 ether;
  ```

</details>

## L-8: Unused Import

Redundant import statement. Consider removing it.

<details><summary>1 Found Instances</summary>

- Found in src/interfaces/InvestableUniverseAdapter.sol [Line: 4](src/interfaces/InvestableUniverseAdapter.sol#L4)

  ```solidity
  import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
  ```

</details>

## L-9: Unchecked Return

Function returns a value but it is ignored. Consider checking the return value.

<details><summary>3 Found Instances</summary>

- Found in src/protocol/VaultShares.sol [Line: 75](src/protocol/VaultShares.sol#L75)

  ```solidity
              _uniswapDivest(IERC20(asset()), uniswapLiquidityTokensBalance);
  ```

- Found in src/protocol/VaultShares.sol [Line: 78](src/protocol/VaultShares.sol#L78)

  ```solidity
              _aaveDivest(IERC20(asset()), aaveAtokensBalance);
  ```

- Found in src/protocol/investableUniverseAdapters/AaveAdapter.sol [Line: 44](src/protocol/investableUniverseAdapters/AaveAdapter.sol#L44)

  ```solidity
          i_aavePool.withdraw({asset: address(token), amount: amount, to: address(this)});
  ```

</details>

### [L-10] Incorrect Event emit

**Description:**
Event is emitted with same values twice, when we expect an old and new value in src/protocol/VaultGuardians.sol:updateGuardianStakePrice function

```solidity
    function updateGuardianStakePrice(uint256 newStakePrice) external onlyOwner {
        s_guardianStakePrice = newStakePrice;
        emit VaultGuardians__UpdatedStakePrice(s_guardianStakePrice, newStakePrice);
    }
```

```solidity
    function updateGuardianAndDaoCut(uint256 newCut) external onlyOwner {
        s_guardianAndDaoCut = newCut;
        //a gas, use newCut instead of storage
        emit VaultGuardians__UpdatedStakePrice(s_guardianAndDaoCut, newCut);
    }
```

**Impact:**
It might cause issues with frontend or other services

**Recommended Mitigation:**

```diff
    function updateGuardianStakePrice(uint256 newStakePrice) external onlyOwner {
+       emit VaultGuardians__UpdatedStakePrice(s_guardianStakePrice, newStakePrice);
        s_guardianStakePrice = newStakePrice;
-       emit VaultGuardians__UpdatedStakePrice(s_guardianStakePrice, newStakePrice);
    }
```

```diff
    function updateGuardianAndDaoCut(uint256 newCut) external onlyOwner {
+       emit VaultGuardians__UpdatedStakePrice(s_guardianAndDaoCut, newCut);
        s_guardianAndDaoCut = newCut;
-       emit VaultGuardians__UpdatedStakePrice(s_guardianAndDaoCut, newCut);
    }
```

# Gas

## G-1: Gas optimizations to avoid reading from storage, when memory reading is possible for the same result

Events can use memory variables for emitting same, rather than reading from storage

<details><summary>2 Found Instances</summary>

- Found in src/protocol/VaultGuardians.sol

  ```solidity
  function updateGuardianStakePrice(uint256 newStakePrice) external onlyOwner {
        s_guardianStakePrice = newStakePrice;
        emit VaultGuardians__UpdatedStakePrice(s_guardianStakePrice, newStakePrice);
    }

  ```

  Recommended Mitigation:

  ```diff
  function updateGuardianStakePrice(uint256 newStakePrice) external onlyOwner {
  +       emit VaultGuardians__UpdatedStakePrice(s_guardianStakePrice, newStakePrice);
        s_guardianStakePrice = newStakePrice;
  -       emit VaultGuardians__UpdatedStakePrice(s_guardianStakePrice, newStakePrice);
    }
  ```

- Found in src/interfaces/IVaultGuardians.sol

  ```solidity
  interface IVaultGuardians {}
  ```

</details>

## G-2: Public Function Not Used Internally

If a function is marked public but is not used internally, consider marking it as `external`.

<details><summary>2 Found Instances</summary>

- Found in src/protocol/VaultShares.sol [Line: 117](src/protocol/VaultShares.sol#L117)

  ```solidity
      function setNotActive() public onlyVaultGuardians isActive {
  ```

- Found in src/protocol/VaultShares.sol [Line: 185](src/protocol/VaultShares.sol#L185)

  ```solidity
      function rebalanceFunds() public isActive divestThenInvest nonReentrant {}
  ```

</details>

# Info

## I-1: Empty interfaces

Some Interfaces are empty and are of no use.

<details><summary>2 Found Instances</summary>

- Found in src/interfaces/InvestableUniverseAdapter.sol

  ```solidity
  interface IInvestableUniverseAdapter {
  // function invest(IERC20 token, uint256 amount) external;
  // function divest(IERC20 token, uint256 amount) external;
  }

  ```

- Found in src/interfaces/IVaultGuardians.sol

  ```solidity
  interface IVaultGuardians {}
  ```

</details>
