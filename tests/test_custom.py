import brownie
from brownie import *
from helpers.constants import MaxUint256
from helpers.SnapshotManager import SnapshotManager
from helpers.time import days

"""
  TODO: Put your tests here to prove the strat is good!
  See test_harvest_flow, for the basic tests
  See test_strategy_permissions, for tests at the permissions level
"""


def test_custom_deposit(deployer, sett, strategy, want, controller):
    # Setup
    startingBalance = want.balanceOf(deployer)

    depositAmount = startingBalance // 2
    assert startingBalance >= depositAmount
    assert startingBalance >= 0
    # End Setup
    print("Setup Complete")

    # Deposit
    assert want.balanceOf(sett) == 0

    want.approve(sett, MaxUint256, {"from": deployer})
    sett.deposit(depositAmount, {"from": deployer})

    available = sett.available()
    assert available > 0
    print("Avaiable amount in sett: ", sett.available())

    # Assert Balance of Pool before deposit == 0
    assert strategy.balanceOfPool() == 0

    sett.earn({"from": deployer})

    # Assert Balance of Pool after deposit > 0
    assert strategy.balanceOfPool() > 0

    amountLPComponent = strategy.balanceOfLP()

    print("Amount of LPComponent(BAL-WBTC-WETH-USDC-Token):", amountLPComponent)

    # Assert the balance of LPComponent after deposit > 0
    assert amountLPComponent > 0


def test_custom_withdraw_all(deployer, sett, strategy, want, controller):
    # Setup
    startingBalance = want.balanceOf(deployer)

    depositAmount = startingBalance // 2
    assert startingBalance >= depositAmount
    assert startingBalance >= 0
    # End Setup
    print("Setup Complete")

    # Deposit
    assert want.balanceOf(sett) == 0

    want.approve(sett, MaxUint256, {"from": deployer})
    sett.deposit(depositAmount, {"from": deployer})

    available = sett.available()
    assert available > 0
    print("Avaiable amount in sett: ", sett.available())

    # Assert Balance of Pool before deposit == 0
    assert strategy.balanceOfPool() == 0

    sett.earn({"from": deployer})

    # Assert Balance of Pool after deposit > 0
    assert strategy.balanceOfPool() > 0

    # Deposit complete

    slippage = 0.9975
    beforeBalanceOfPool = strategy.balanceOfPool()

    # Withdraw
    controller.withdrawAll(strategy.want(), {"from": deployer})

    assert (
        strategy.balanceOfLP() == 0
    )  # After withdrawAll no LPComponent should be there

    # Balance of Pool should be 0 after withdrawall
    assert strategy.balanceOfPool() == 0


def test_custom_withdraw_some(deployer, sett, strategy, want, controller, vault):
    # Setup
    startingBalance = want.balanceOf(deployer)

    depositAmount = startingBalance // 2
    assert startingBalance >= depositAmount
    assert startingBalance >= 0
    # End Setup
    print("Setup Complete")

    # Deposit
    assert want.balanceOf(sett) == 0

    want.approve(sett, MaxUint256, {"from": deployer})
    sett.deposit(depositAmount, {"from": deployer})

    available = sett.available()
    assert available > 0
    print("Avaiable amount in sett: ", sett.available())

    # Assert Balance of Pool before deposit == 0
    assert strategy.balanceOfPool() == 0

    sett.earn({"from": deployer})

    # Assert Balance of Pool after deposit > 0
    assert strategy.balanceOfPool() > 0

    # Deposit complete

    beforeLP = strategy.balanceOfLP()
    beforePoolBalance = strategy.balanceOfPool()

    # Withdraw 1/10th amount of whatever we deposited into sett
    _toWithdraw = depositAmount // 10

    # Withdraw
    controller.withdraw(strategy.want(), _toWithdraw, {"from": vault})

    slippage = 0.9975  # 0.25% slippage

    afterLP = strategy.balanceOfLP()
    afterPoolBalance = strategy.balanceOfPool()

    # Difference in Pool balance should be equal to the amount we withdrew
    assert (beforePoolBalance - afterPoolBalance) == _toWithdraw
