// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title GaussianRef
/// @notice Standard normal CDF and PDF in WAD (1e18) fixed point.
/// @dev Method for the CDF: the upper tail is 1 - Phi(a) = phi(a) * M(a) for a = |z|, where M is the
///      Mills ratio, sqrt(pi / 2) * erfcx(a / sqrt 2): smooth, between 0.11 and 1.26 on [0, 9]. M is a
///      polynomial of degree 14 on each of 18 intervals of width 0.5 (Chebyshev fits, error below 1.2e-20,
///      made by test/vectors/gen_mills.py), in the local variable t in [-1, 1] at 1e36 scale, by Horner.
///      phi(a) is not formed in WAD (it can be as small as 1e-18): exp(40 - a^2 / 2) is taken (between 0.6
///      and 2.4e35 in WAD; solady's expWad is exact to below 1e-19 relative there), multiplied by M, and
///      divided once by e^40 * sqrt(2 pi) * 1e36. Negative arguments use Phi(-z) = 1 - Phi(z), so
///      cdf(z) + cdf(-z) = 1e18 exactly; for |z| >= 9 the tail is below 1.2e-19 and the result is 0 or 1e18.
///
///      Error bound for the CDF, in wei of WAD: the fit below 1e-2, the coefficients and the Horner steps at
///      1e36 below 1e-15, z^2 / 2 truncated to WAD and expWad below 0.6, the final division rounds down:
///      below 2 wei in all. The tests assert at most 2 wei against a 90-digit reference over the whole
///      range, far inside the 1e-9 the spec requires. Gas: about 1.2k a call.
///
///      PDF: exp(-z^2 / 2) from expWad times 1 / sqrt(2 pi), each rounded down. Error below 3 wei.
library GaussianRef {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant HALF = 5e17;

    /// @dev |z| at and beyond which the CDF is returned as exactly 0 or 1e18. Phi(-9) = 1.13e-19.
    uint256 internal constant CDF_CUTOFF = 9e18;

    /// @dev |z| at and beyond which the PDF is returned as 0. phi(9.2) = 1.7e-19.
    uint256 internal constant PDF_CUTOFF = 9.2e18;

    /// @dev e^40 * sqrt(2 pi) * 1e36, rounded to the nearest integer.
    uint256 internal constant E40_SQRT_2PI_E36 = 590023365285237066961937924728842176883135759177089817;

    /// @dev 1 / sqrt(2 pi) in WAD, rounded to the nearest integer.
    uint256 internal constant INV_SQRT_2PI = 398942280401432678;

    /// @dev Scale of the polynomial's variable and coefficients.
    int256 internal constant S = 1e36;

    /// @notice Standard normal CDF Phi(z), WAD in and WAD out. Absolute error below 2e-18.
    function cdf(int256 z) internal pure returns (uint256) {
        uint256 a = FixedPointMathLib.abs(z);
        if (a >= CDF_CUTOFF) return z < 0 ? 0 : WAD;
        if (a == 0) return HALF;
        // a < 9e18: the interval k < 18, t = (a - its midpoint) / 0.25 in [-1, 1] at 1e36.
        uint256 k = a / 5e17;
        int256 t = (int256(a) - int256(k * 5e17 + 25e16)) * 4e18;
        int256 m = _mills(k, t);
        // exp(40 - a^2 / 2) in WAD, at most 2.36e35; times M (below 1.3e36): below 3.1e71.
        uint256 e = uint256(FixedPointMathLib.expWad(40e18 - int256(a * a / (2 * WAD))));
        uint256 h = e * uint256(m) / E40_SQRT_2PI_E36;
        if (h > HALF) h = HALF;
        return z < 0 ? h : WAD - h;
    }

    /// @dev M(a) at 1e36 on interval k, from t. Horner with |acc| < 1.1e36 and |t| <= 1e36, so no product
    ///      exceeds 1.2e72 and nothing overflows.
    function _mills(uint256 k, int256 t) private pure returns (int256 acc) {
        unchecked {
            if (k <= 8) {
                if (k <= 4) {
                    if (k <= 2) {
                        if (k <= 1) {
                            if (k <= 0) {
                                acc = 2874681320696674143332;
                                acc = acc * t / S - 45324484848755813692802;
                                acc = acc * t / S + 679738949714677763391907;
                                acc = acc * t / S - 9969288282395181160695034;
                                acc = acc * t / S + 140491539256900725437362670;
                                acc = acc * t / S - 1895261331951149799103382471;
                                acc = acc * t / S + 24373899611806938709903017769;
                                acc = acc * t / S - 297291422023461797236159437789;
                                acc = acc * t / S + 3417150575014912961810930660648;
                                acc = acc * t / S - 36713789876440666328882263111877;
                                acc = acc * t / S + 364760245077433984727204145490009;
                                acc = acc * t / S - 3301863435187468989800034818929139;
                                acc = acc * t / S + 26646519120143273074294962542225702;
                                acc = acc * t / S - 185135964009142074392880640660365859;
                                acc = acc * t / S + 1037824575853726812300364706133962572;
                            } else {
                                acc = 481058720220285490944;
                                acc = acc * t / S - 8104560490635029884771;
                                acc = acc * t / S + 130453541342777766356055;
                                acc = acc * t / S - 2055462253944380220835337;
                                acc = acc * t / S + 31215612658604010408625572;
                                acc = acc * t / S - 455435665876749148535729932;
                                acc = acc * t / S + 6360803597574299686363253159;
                                acc = acc * t / S - 84665129512255569157671821533;
                                acc = acc * t / S + 1068178249521945433445030373224;
                                acc = acc * t / S - 12687029259399534795219739973765;
                                acc = acc * t / S + 140606199732219637998254375187327;
                                acc = acc * t / S - 1436780939947802731274670787535902;
                                acc = acc * t / S + 13309139602705471263895416863964987;
                                acc = acc * t / S - 108892903925610990377471073659954887;
                                acc = acc * t / S + 752571179063408051455473357909554752;
                            }
                        } else {
                            acc = 89944402110262453180;
                            acc = acc * t / S - 1618275490906233212414;
                            acc = acc * t / S + 27932419576317300139525;
                            acc = acc * t / S - 472465996802106729952052;
                            acc = acc * t / S + 7725768122219591322801548;
                            acc = acc * t / S - 121787675243472400407592398;
                            acc = acc * t / S + 1845060995112458547630707761;
                            acc = acc * t / S - 26762727199057929952966852114;
                            acc = acc * t / S + 369981443470074239209454646751;
                            acc = acc * t / S - 4847332664602919228830112888798;
                            acc = acc * t / S + 59754881896123669882510017780292;
                            acc = acc * t / S - 686561022648708209009829143516305;
                            acc = acc * t / S + 7257117554595457308785436496900371;
                            acc = acc * t / S - 69240516860115288556447741472941144;
                            acc = acc * t / S + 578430346047631076633612490494802729;
                        }
                    } else {
                        if (k <= 3) {
                            acc = 18641922269421253464;
                            acc = acc * t / S - 357899902861915090872;
                            acc = acc * t / S + 6616819396383982663232;
                            acc = acc * t / S - 120021912879200134261797;
                            acc = acc * t / S + 2110670665792042659765871;
                            acc = acc * t / S - 35899489191166438452105927;
                            acc = acc * t / S + 589003670137004796997666375;
                            acc = acc * t / S - 9292551548396720109493167303;
                            acc = acc * t / S + 140440330638515672137955914915;
                            acc = acc * t / S - 2023848088076497130927741533247;
                            acc = acc * t / S + 27649208357828876555006196447259;
                            acc = acc * t / S - 355452305550893943366843031019109;
                            acc = acc * t / S + 4257715473757306032117063766959985;
                            acc = acc * t / S - 46865718982744053059564817617655799;
                            acc = acc * t / S + 464306928039442164437260864256198280;
                        } else {
                            acc = 4250540599267827501;
                            acc = acc * t / S - 86986843581232488677;
                            acc = acc * t / S + 1720200550217808911582;
                            acc = acc * t / S - 33416702479196165678578;
                            acc = acc * t / S + 631049325217845489179419;
                            acc = acc * t / S - 11560984546984267383627270;
                            acc = acc * t / S + 205016738603090160627583460;
                            acc = acc * t / S - 3509932296592949546888952995;
                            acc = acc * t / S + 57831533215871458837321200781;
                            acc = acc * t / S - 913596216201211881158253790273;
                            acc = acc * t / S + 13774193134533557614037313377875;
                            acc = acc * t / S - 197055435506892976252844816384336;
                            acc = acc * t / S + 2655047280172184556674941905340362;
                            acc = acc * t / S - 33354086425880524203073452711213921;
                            acc = acc * t / S + 385148290798434623639310661148916299;
                        }
                    }
                } else {
                    if (k <= 6) {
                        if (k <= 5) {
                            acc = 1058482577114275751;
                            acc = acc * t / S - 23061806097090037144;
                            acc = acc * t / S + 487061860700725101800;
                            acc = acc * t / S - 10117428727081585682928;
                            acc = acc * t / S + 204812793627523666495698;
                            acc = acc * t / S - 4033655279723258992376908;
                            acc = acc * t / S + 77140251372641368496832910;
                            acc = acc * t / S - 1429389095948507845749331347;
                            acc = acc * t / S + 25597232232521348562661695977;
                            acc = acc * t / S - 441661133313330894486679815909;
                            acc = acc * t / S + 7315606760768422187839425601618;
                            acc = acc * t / S - 115804565033517711355244681245370;
                            acc = acc * t / S + 1742049048057873867374106545067235;
                            acc = acc * t / S - 24721158650245462764167518246742979;
                            acc = acc * t / S + 327678314690552054161274179708510335;
                        } else {
                            acc = 285912216231763655;
                            acc = acc * t / S - 6622716569608003764;
                            acc = acc * t / S + 149127810951538012527;
                            acc = acc * t / S - 3306743165985787591332;
                            acc = acc * t / S + 71621628133118798971921;
                            acc = acc * t / S - 1513079947916512723869747;
                            acc = acc * t / S + 31129498803053333365210907;
                            acc = acc * t / S - 622566989449735769126671457;
                            acc = acc * t / S + 12077946710026866985462027517;
                            acc = acc * t / S - 226740810051102581507604364233;
                            acc = acc * t / S + 4107113414826836936635936564546;
                            acc = acc * t / S - 71531739196836729308249794242881;
                            acc = acc * t / S + 1192767868107795051425886437612790;
                            acc = acc * t / S - 18939505766849498695184170099811004;
                            acc = acc * t / S + 284382146748492924682863883679537965;
                        }
                    } else {
                        if (k <= 7) {
                            acc = 83234370874983365;
                            acc = acc * t / S - 2046640958285935274;
                            acc = acc * t / S + 49047642223428287067;
                            acc = acc * t / S - 1158822196136615067004;
                            acc = acc * t / S + 26799901470724389681044;
                            acc = acc * t / S - 605954520432939542790387;
                            acc = acc * t / S + 13377301737981946666549991;
                            acc = acc * t / S - 287916974954830105881486703;
                            acc = acc * t / S + 6031049246901096282190351488;
                            acc = acc * t / S - 122712439899111930170973567202;
                            acc = acc * t / S + 2419667326189161175720348530358;
                            acc = acc * t / S - 46112005084766273883928031267521;
                            acc = acc * t / S + 846538785147600425493864880578650;
                            acc = acc * t / S - 14911458021282787534289358214280760;
                            acc = acc * t / S + 250761111443965026630094596361900926;
                        } else {
                            acc = 25959739984230890;
                            acc = acc * t / S - 676518156098897233;
                            acc = acc * t / S + 17222807464197836697;
                            acc = acc * t / S - 432739134878602407911;
                            acc = acc * t / S + 10663477251721673337828;
                            acc = acc * t / S - 257442171118830549957912;
                            acc = acc * t / S + 6082673172757328379511976;
                            acc = acc * t / S - 140477115971716728145428628;
                            acc = acc * t / S + 3166693137669569176092133117;
                            acc = acc * t / S - 69567220329407836806784056396;
                            acc = acc * t / S + 1486645286816204432440940477284;
                            acc = acc * t / S - 30838347502228073366002888490001;
                            acc = acc * t / S + 619397205894114331546844224471444;
                            acc = acc * t / S - 12009993180306891159471502667133843;
                            acc = acc * t / S + 223990594653828808320498253130337764;
                        }
                    }
                }
            } else {
                if (k <= 13) {
                    if (k <= 11) {
                        if (k <= 10) {
                            if (k <= 9) {
                                acc = 8626376615523466;
                                acc = acc * t / S - 237864065938778100;
                                acc = acc * t / S + 6420677706194338737;
                                acc = acc * t / S - 171228233951968863012;
                                acc = acc * t / S + 4486151185130210525815;
                                acc = acc * t / S - 115373346759013505154435;
                                acc = acc * t / S + 2909877745447587811245125;
                                acc = acc * t / S - 71901438906148200769524051;
                                acc = acc * t / S + 1738591690646831441870508385;
                                acc = acc * t / S - 41086203279839053781497843665;
                                acc = acc * t / S + 947542664619035296175440263109;
                                acc = acc * t / S - 21290206890148785832031414175041;
                                acc = acc * t / S + 465156661448445189987536434978318;
                                acc = acc * t / S - 9859906498247600330206074751536092;
                                acc = acc * t / S + 202223236633054652353510911345302721;
                            } else {
                                acc = 3038660006786066;
                                acc = acc * t / S - 88506087572527498;
                                acc = acc * t / S + 2528304909109233110;
                                acc = acc * t / S - 71423416461676119867;
                                acc = acc * t / S + 1985342144123527033305;
                                acc = acc * t / S - 54262808178202713918214;
                                acc = acc * t / S + 1457173703162159968171290;
                                acc = acc * t / S - 38414492080411291418424827;
                                acc = acc * t / S + 993222567697962170600767010;
                                acc = acc * t / S - 25160097034683522750098104615;
                                acc = acc * t / S + 623711404227357427294194129691;
                                acc = acc * t / S - 15110747251549184755566456479457;
                                acc = acc * t / S + 357243222153083755295045847725033;
                                acc = acc * t / S - 8227423533289119729631891308914847;
                                acc = acc * t / S + 184207677307970194491709106925946984;
                            }
                        } else {
                            acc = 1129384086122186;
                            acc = acc * t / S - 34688900404582234;
                            acc = acc * t / S + 1046729778023518217;
                            acc = acc * t / S - 31261759795682430862;
                            acc = acc * t / S + 919998530803828577525;
                            acc = acc * t / S - 26662071870949346718610;
                            acc = acc * t / S + 760427413582748487309818;
                            acc = acc * t / S - 21329168839359592177223776;
                            acc = acc * t / S + 587905592245588521243231776;
                            acc = acc * t / S - 15910695531663956328595172322;
                            acc = acc * t / S + 422384934083847144720160103145;
                            acc = acc * t / S - 10987709126461599763031762060323;
                            acc = acc * t / S + 279749945689983011842864803615728;
                            acc = acc * t / S - 6961658788939766061070954836114289;
                            acc = acc * t / S + 169070150407694075783602837137444916;
                        }
                    } else {
                        if (k <= 12) {
                            acc = 441024357455713;
                            acc = acc * t / S - 14260749352066451;
                            acc = acc * t / S + 453703196152700347;
                            acc = acc * t / S - 14298301927263178862;
                            acc = acc * t / S + 444570896064735083015;
                            acc = acc * t / S - 13630786884768372187594;
                            acc = acc * t / S + 411901013762447354018634;
                            acc = acc * t / S - 12260358647128258361211202;
                            acc = acc * t / S + 359232295940483375236662848;
                            acc = acc * t / S - 10353967566993102665034926026;
                            acc = acc * t / S + 293335489585113831888420313216;
                            acc = acc * t / S - 8161704644987293612439059066301;
                            acc = acc * t / S + 222816087458129625564238464951139;
                            acc = acc * t / S - 5962164009412630732525144201329796;
                            acc = acc * t / S + 156184215033975916331183915605881505;
                        } else {
                            acc = 180245428281098;
                            acc = acc * t / S - 6125761057805803;
                            acc = acc * t / S + 205112725815179141;
                            acc = acc * t / S - 6808109838953139474;
                            acc = acc * t / S + 223201568524665915349;
                            acc = acc * t / S - 7224674875396706026533;
                            acc = acc * t / S + 230778471887456521125545;
                            acc = acc * t / S - 7271371919772608491377084;
                            acc = acc * t / S + 225866686235737725542193153;
                            acc = acc * t / S - 6912794183380483455102843152;
                            acc = acc * t / S + 208328644829903817322383927008;
                            acc = acc * t / S - 6177896945077841589215305813997;
                            acc = acc * t / S + 180136250786215567222615655880637;
                            acc = acc * t / S - 5160217824591556711301562106888302;
                            acc = acc * t / S + 145090241289130929356265743818880130;
                        }
                    }
                } else {
                    if (k <= 15) {
                        if (k <= 14) {
                            acc = 76827713054695;
                            acc = acc * t / S - 2739880521479175;
                            acc = acc * t / S + 96384871173952418;
                            acc = acc * t / S - 3363392860604245422;
                            acc = acc * t / S + 116044699282377859494;
                            acc = acc * t / S - 3957255534015747965884;
                            acc = acc * t / S + 133327562065690625437371;
                            acc = acc * t / S - 4436344095483747880046896;
                            acc = acc * t / S + 145719906713558952546499661;
                            acc = acc * t / S - 4722747833387809222611532386;
                            acc = acc * t / S + 150948798212748102000872385282;
                            acc = acc * t / S - 4755334974840719632862453572506;
                            acc = acc * t / S + 147565437355996747883308401320506;
                            acc = acc * t / S - 4507653762116260230996839587090104;
                            acc = acc * t / S + 135444053096763442631174158546116067;
                        } else {
                            acc = 34043496596665;
                            acc = acc * t / S - 1272002385051717;
                            acc = acc * t / S + 46932999248682573;
                            acc = acc * t / S - 1718795365842568949;
                            acc = acc * t / S + 62293975156094431865;
                            acc = acc * t / S - 2233622107874023446394;
                            acc = acc * t / S + 79209321232569217220446;
                            acc = acc * t / S - 2777130541184996103874243;
                            acc = acc * t / S + 96229839894558246651770728;
                            acc = acc * t / S - 3294163657344202909519828027;
                            acc = acc * t / S + 111357138007547870707107911654;
                            acc = acc * t / S - 3715604370821520198028396455010;
                            acc = acc * t / S + 122310592327950189865143212699927;
                            acc = acc * t / S - 3969977371965888855326283277081772;
                            acc = acc * t / S + 126983237485436960590799338089860743;
                        }
                    } else {
                        if (k <= 16) {
                            acc = 15636911833458;
                            acc = acc * t / S - 611208690182485;
                            acc = acc * t / S + 23615113207813724;
                            acc = acc * t / S - 906120781424177564;
                            acc = acc * t / S + 34436171890771829955;
                            acc = acc * t / S - 1295871322566841958364;
                            acc = acc * t / S + 48273541084152620785633;
                            acc = acc * t / S - 1779632325981269436218529;
                            acc = acc * t / S + 64906880016178670092667713;
                            acc = acc * t / S - 2341245861043876366166066908;
                            acc = acc * t / S + 83492173896001067229068369668;
                            acc = acc * t / S - 2942541407451545316141674689023;
                            acc = acc * t / S + 102447365575245063735804672368942;
                            acc = acc * t / S - 3522005051540761278457005137321333;
                            acc = acc * t / S + 119504482399252964228626906776091256;
                        } else {
                            acc = 7425437722312;
                            acc = acc * t / S - 303189526283161;
                            acc = acc * t / S + 12247607781239706;
                            acc = acc * t / S - 491588974508966480;
                            acc = acc * t / S + 19557195004808562087;
                            acc = acc * t / S - 771021663282527628505;
                            acc = acc * t / S + 30114909385544967013509;
                            acc = acc * t / S - 1165048947895135828157841;
                            acc = acc * t / S + 44631421577691584139002744;
                            acc = acc * t / S - 1692585237383496172406268581;
                            acc = acc * t / S + 63525099779880755627292451428;
                            acc = acc * t / S - 2358785311286506135420757867495;
                            acc = acc * t / S + 86623092280940083100098513290544;
                            acc = acc * t / S - 3145029924774655203003940269534014;
                            acc = acc * t / S + 112847986320103014764341055952270526;
                        }
                    }
                }
            }
        }
    }

    /// @notice Standard normal density phi(z) = exp(-z^2 / 2) / sqrt(2 pi), WAD in and WAD out. Absolute
    ///         error below 3e-18.
    function pdf(int256 z) internal pure returns (uint256) {
        uint256 a = FixedPointMathLib.abs(z);
        if (a >= PDF_CUTOFF) return 0;
        uint256 e = uint256(FixedPointMathLib.expWad(-int256(a * a / (2 * WAD))));
        return e * INV_SQRT_2PI / WAD;
    }
}
