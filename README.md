# Yearn-Strategies
Yearn sample strategies

ApeStrategy to work with Yearn Vault.The strategy provides liquidity to protocol P, 
receiving yield(Y token) and R reward(R token), then reinvests income received in P at a regular basis in order to secure higher yield.
Reinvesting occurs by staking the Y token into P protocol's `Pstakepool` pool.

