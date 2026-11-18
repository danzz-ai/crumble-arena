// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test-only mock of the SPACE ID Agent ID contract (0x60b92624...).
///         Mirrors the real interface: ownerOf reverts for nonexistent tokens,
///         balanceOf counts holdings, handleOf returns "" for non-holders.
contract MockAgentId {
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(address => string) private _handles;

    error NonexistentToken(uint256 tokenId);

    function mint(address to, uint256 tokenId, string calldata handle) external {
        _owners[tokenId] = to;
        _balances[to] += 1;
        _handles[to] = handle;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address o = _owners[tokenId];
        if (o == address(0)) revert NonexistentToken(tokenId);
        return o;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return _balances[owner];
    }

    function handleOf(address owner) external view returns (string memory) {
        return _handles[owner];
    }
}
