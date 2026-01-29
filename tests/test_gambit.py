import pytest
from ape import project, Contract, accounts, networks
from eth_utils import to_checksum_address

CTF_ADDRESS=to_checksum_address("0x6F384Fec5eDEc49a7A6B6bC4b619A76197120B88")
USDC_ADDRESS =to_checksum_address("0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238")
WHALE_ADDRESS = "0x3C3380cdFb94dFEEaA41cAD9F58254AE380d752D"

@pytest.fixture
def usdc():
    # Load the ABI from our OpenZeppelin dependency
    oz = project.dependencies["openzeppelin"]["5.0.0"]
    usdc_abi = oz.ERC20.contract_type 
    
    # We pass the ABI directly so Ape doesn't try to use an explorer
    return Contract(USDC_ADDRESS, contract_type=usdc_abi)


def test_usdc_connection(usdc):
    assert usdc.symbol() == "USDC"
    print(f"✅ Successfully connected to {usdc.name()} on Sepolia Fork!")
