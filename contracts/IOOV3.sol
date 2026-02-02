// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./vendor/@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IOOV3 {
    function getMinimumBond(address currency) external view returns (uint256);
    function assertTruth(
        bytes calldata claim,
        address asserter,
        address callbackRecipient,
        address escalationManager,
        uint64 liveness,
        IERC20 currency,
        uint256 bond,
        bytes32 identifier,
        bytes32 domainId
    ) external returns (bytes32 assertionId);

    function settleAndGetAssertionResult(bytes32 assertionId) external returns (bool);
    function getAssertionResult(bytes32 assertionId) external view returns (bool);
    function defaultIdentifier() external view returns (bytes32);
}
