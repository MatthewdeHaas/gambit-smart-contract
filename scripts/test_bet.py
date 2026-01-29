import pytest
from ape import networks, accounts, project, Contract
import os
from eth_abi import encode
from eth_utils import keccak, encode_hex, decode_hex, to_checksum_address
from datetime import datetime, timedelta

CTF_ADDRESS=to_checksum_address("0x6F384Fec5eDEc49a7A6B6bC4b619A76197120B88")
USDC_ADDRESS =to_checksum_address("0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238")
WHALE_ADDRESS = "0x3C3380cdFb94dFEEaA41cAD9F58254AE380d752D"

def test_full_bet_lifecycle():
    user_a = accounts.test_accounts[0]
    user_b = accounts.test_accounts[1]

    oz = project.dependencies["openzeppelin"]["5.0.0"]
    usdc_abi = oz.ERC20.contract_type  
    usdc = Contract(USDC_ADDRESS, contract_type=usdc_abi)

    with accounts.use_sender(WHALE_ADDRESS):
        whale = accounts[WHALE_ADDRESS]

        # 2. ENSURE GAS (Already doing this, but keep it!)
        networks.active_provider.set_balance(WHALE_ADDRESS, "1 ether")

        # 3. VERIFY BALANCE (Debugging)
        print(f"Whale USDC Balance: {usdc.balanceOf(WHALE_ADDRESS) / 1e6} USDC")

        # 4. TRANSFER
        # Now this will work because we are inside the 'use_sender' context
        usdc.transfer(user_a, 1000 * 10**6, sender=whale, gas_limit=2000000)

    amount = 10 * 10**6
    prob = 40 * 10**16

    for acct in [user_a, user_b]:
        networks.active_provider.set_balance(acct.address, "10 ether")

    usdc.transfer(user_a, 100 * 10**6, sender=whale, gas_limit=2000000)
    usdc.transfer(user_b, 100 * 10**6, sender=whale, gas_limit=2000000)

    networks.active_provider.set_balance(user_a.address, "10 ether")

    # Set the initial account balances for testing
    initial_balance_a = usdc.balanceOf(user_a.address)
    initial_balance_b = usdc.balanceOf(user_b.address)

    # 3. Deploy your contract
    gambit = user_a.deploy(project.Gambit, CTF_ADDRESS, USDC_ADDRESS, gas_limit=2000000)

    # Define everything
    question_id = os.urandom(32)
    outcome_slot_count = 2
    oracle = to_checksum_address(user_a.address)
    end_timestamp = int((datetime.now() + timedelta(days=7)).timestamp())

    # Approve and Create bet
    print("Creating bet...")
    usdc.approve(gambit.address, amount, sender=user_a, gas_limit=2000000)
    receipt = gambit.createBet(amount, prob, question_id, end_timestamp, sender=user_a, gas_limit=2000000)
    print("✅ Bet created!")

    # Approve and challenge bet
    print("Challenging bet...")
    usdc.approve(gambit.address, 15 * 10**6, sender=user_b, gas_limit=2000000)
    gambit.challengeBet(question_id, sender=user_b, gas_limit=2000000)
    print("✅ Bet challenged!")

    # 6. Assertions
    assert usdc.balanceOf(user_a.address) == initial_balance_a - (10 * 10**6)
    assert usdc.balanceOf(user_b.address) == initial_balance_b - (15 * 10**6)
    print("✅ Math verified! User A and B balances updated correctly.")





def main():
    test_full_bet_lifecycle()
