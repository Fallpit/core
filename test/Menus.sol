// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PitMath} from "../src/hook/PitMath.sol";

/// @notice Menus the tests open rounds with, as `IPitBook.Params.menu` words.
library Menus {
    /// @dev The book's default, written out: eight floors that partition the ladder, then LOWER, HIGHER.
    function standard() internal pure returns (uint256) {
        uint8[2][] memory r = new uint8[2][](10);
        r[0] = [0, 11];
        r[1] = [12, 15];
        r[2] = [16, 17];
        r[3] = [18, 19];
        r[4] = [20, 21];
        r[5] = [22, 23];
        r[6] = [24, 27];
        r[7] = [28, 39];
        r[8] = [0, 19];
        r[9] = [20, 39];
        return pack(r);
    }

    /// @dev Six floors that partition the ladder (below -1.5 sigma, -1.5 to -0.5, -0.5 to 0, 0 to 0.5,
    ///      0.5 to 1.5, above 1.5), then LOWER (index 6) and HIGHER (index 7).
    function sixFloorsAndPair() internal pure returns (uint256) {
        uint8[2][] memory r = new uint8[2][](8);
        r[0] = [0, 13];
        r[1] = [14, 17];
        r[2] = [18, 19];
        r[3] = [20, 21];
        r[4] = [22, 25];
        r[5] = [26, 39];
        r[6] = [0, 19];
        r[7] = [20, 39];
        return pack(r);
    }

    /// @dev A six-product threshold menu: HIGHER and LOWER at the strikes one sigma below the previous
    ///      close, at it, and one sigma above (edges 15, 19, 23). Index i is strike `i / 2`, side `i % 2`
    ///      (0 HIGHER, 1 LOWER).
    function thresholds() internal pure returns (uint256) {
        uint8[2][] memory r = new uint8[2][](6);
        r[0] = [16, 39];
        r[1] = [0, 15];
        r[2] = [20, 39];
        r[3] = [0, 19];
        r[4] = [24, 39];
        r[5] = [0, 23];
        return pack(r);
    }

    /// @dev A menu that does not partition the ladder: bands 10 to 14 and 30 to 39 belong to no product,
    ///      bands 18 to 21 to two (the straddle of index 3 overlaps the floors of indices 1 and 2).
    function gappy() internal pure returns (uint256) {
        uint8[2][] memory r = new uint8[2][](5);
        r[0] = [0, 9];
        r[1] = [15, 19];
        r[2] = [20, 24];
        r[3] = [18, 21];
        r[4] = [25, 29];
        return pack(r);
    }

    /// @dev The smallest menu: the pair alone.
    function pairOnly() internal pure returns (uint256) {
        uint8[2][] memory r = new uint8[2][](2);
        r[0] = [0, 19];
        r[1] = [20, 39];
        return pack(r);
    }

    function pack(uint8[2][] memory runs) internal pure returns (uint256) {
        uint8[] memory lo = new uint8[](runs.length);
        uint8[] memory hi = new uint8[](runs.length);
        for (uint256 i; i < runs.length; ++i) {
            (lo[i], hi[i]) = (runs[i][0], runs[i][1]);
        }
        return PitMath.pack(lo, hi);
    }
}

/// @notice Product indices of the book's default menu (`Menus.standard`), for tests that trade it.
abstract contract StandardMenu {
    /// @dev Floors, by standard deviations of the day from the previous close.
    uint8 internal constant F0 = 0; // below -2: bands 0 to 11
    uint8 internal constant F1 = 1; // -2 to -1: bands 12 to 15
    uint8 internal constant F2 = 2; // -1 to -0.5: bands 16 to 17
    uint8 internal constant F3 = 3; // -0.5 to 0: bands 18 to 19
    uint8 internal constant F4 = 4; // 0 to 0.5: bands 20 to 21
    uint8 internal constant F5 = 5; // 0.5 to 1: bands 22 to 23
    uint8 internal constant F6 = 6; // 1 to 2: bands 24 to 27
    uint8 internal constant F7 = 7; // above 2: bands 28 to 39
    /// @dev The beginner pair at the previous close.
    uint8 internal constant LOWER = 8; // bands 0 to 19
    uint8 internal constant HIGHER = 9; // bands 20 to 39
    /// @dev Number of products of the default menu, and the most a menu can have.
    uint256 internal constant PRODUCTS = 10;
    uint256 internal constant MAX_PRODUCTS = 12;
}
