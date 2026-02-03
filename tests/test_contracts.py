import pytest
import os
from ape import project, Contract, accounts, networks
from eth_utils import to_checksum_address
from dotenv import load_dotenv


load_dotenv()
USDC_ADDRESS = to_checksum_address(os.getenv("USDC_ADDRESS"))
CTF_ADDRESS = to_checksum_address(os.getenv("CTF_ADDRESS"))
OO_ADDRESS = to_checksum_address(os.getenv("OO_ADDRESS"))

@pytest.fixture
def usdc():
    return project.IERC20.at(USDC_ADDRESS)

@pytest.fixture
def ctf():
    return project.IConditionalTokens.at(CTF_ADDRESS)

@pytest.fixture
def oo():
    return project.IOOV3.at(OO_ADDRESS)


def test_contract_connections(usdc, ctf, oo):

    code = networks.provider.get_code(oo.address)
    assert len(code) > 2, f"No contract code found at {oo.address}. Check your fork network!"

    assert usdc.symbol() == "USDC"
    assert ctf.address == CTF_ADDRESS 
    # assert len(oo.defaultIdentifier()) == 66  # Standard length for 0x + 64 hex chars
    
    print("✅ Contracts are correctly mapped and responding!")
