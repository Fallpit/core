// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FallpitHook} from "../src/FallpitHook.sol";
import {PitMath} from "../src/hook/PitMath.sol";
import {IFallpitHook} from "../src/interfaces/IFallpitHook.sol";

/// @notice A product's ticket in the tests: an ERC-6909 id of the hook, with token-style calls on it
///         (`balanceOf`, `totalSupply`, `transfer`, ...). `transfer` and `approve` are external calls of the
///         test contract to the hook, so a `vm.prank` before them acts as that user.
struct Ticket {
    FallpitHook hook;
    uint256 id;
}

using {balanceOf, totalSupply, transfer, approve, decimals, lo, hi, low, high, isZero} for Ticket global;

function balanceOf(Ticket memory t, address owner) view returns (uint256) {
    return t.hook.balanceOf(owner, t.id);
}

/// @dev Every ticket of the id there is: the round's outstanding supply of the product.
function totalSupply(Ticket memory t) view returns (uint256) {
    (bytes32 roundId, uint8 index) = t.hook.tokenRef(t.id);
    (uint256[12] memory supply,) = t.hook.getSupplies(roundId);
    return supply[index];
}

function transfer(Ticket memory t, address to, uint256 amount) returns (bool) {
    return t.hook.transfer(to, t.id, amount);
}

/// @dev An ERC-6909 allowance. A sell needs none (the router escrows through `hook.pull`); a test that
///      approves before a sell does no harm.
function approve(Ticket memory t, address spender, uint256 amount) returns (bool) {
    return t.hook.approve(spender, t.id, amount);
}

function decimals(Ticket memory t) view returns (uint8) {
    return t.hook.decimals(t.id);
}

/// @dev The product's run of bands and its price range, from the `PitMath` formulas on the round's config.
function lo(Ticket memory t) view returns (uint8 l) {
    (bytes32 roundId, uint8 index) = t.hook.tokenRef(t.id);
    (l,) = PitMath.run(t.hook.getConfig(roundId).params.menu, index);
}

function hi(Ticket memory t) view returns (uint8 h) {
    (bytes32 roundId, uint8 index) = t.hook.tokenRef(t.id);
    (, h) = PitMath.run(t.hook.getConfig(roundId).params.menu, index);
}

function low(Ticket memory t) view returns (uint256 l) {
    (l,) = _bounds(t);
}

function high(Ticket memory t) view returns (uint256 h) {
    (, h) = _bounds(t);
}

function _bounds(Ticket memory t) view returns (uint256, uint256) {
    (bytes32 roundId, uint8 index) = t.hook.tokenRef(t.id);
    IFallpitHook.RoundConfig memory c = t.hook.getConfig(roundId);
    (uint8 l, uint8 h) = PitMath.run(c.params.menu, index);
    return PitMath.bounds(c.s0, c.sigma, l, h);
}

function isZero(Ticket memory t) pure returns (bool) {
    return t.id == 0;
}

/// @dev The tickets of a round, index = product; id zero above the menu (and for an unknown round).
function ticketsOf(FallpitHook hook, bytes32 roundId) view returns (Ticket[12] memory out) {
    uint256 n = PitMath.count(hook.getConfig(roundId).params.menu);
    if (hook.getState(roundId).status == IFallpitHook.Status.None) n = 0;
    for (uint256 i; i < 12; ++i) {
        out[i] = Ticket(hook, i < n ? hook.tokenId(roundId, uint8(i)) : 0);
    }
}

/// @dev The ticket of product `product` of a round.
function ticketOf(FallpitHook hook, bytes32 roundId, uint8 product) pure returns (Ticket memory) {
    return Ticket(hook, uint256(roundId) | product);
}
