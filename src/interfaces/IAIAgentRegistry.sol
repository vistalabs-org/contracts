// src/interfaces/IAIAgentRegistry.sol
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

interface IAIAgentRegistry {
    /**
     * @notice Checks if an agent contract address is registered in the registry.
     * @param agent The address of the agent contract.
     * @return True if the agent is registered, false otherwise.
     */
    function isRegistered(address agent) external view returns (bool);
}
