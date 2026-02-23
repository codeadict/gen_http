-module(gen_http_parser_huffman).

%% @doc Huffman encoding/decoding for HPACK (RFC 7541 Appendix B).
%%
%% This module implements Huffman coding for compressing header field
%% names and values in HTTP/2. Uses direct pattern matching for decoding
%% instead of tree traversal, following the hpax implementation approach.

-export([encode/1, decode/1]).

-export_type([huffman_error/0]).

-type huffman_error() :: {huffman_decode_error, binary()}.

%% @doc Encode a binary string using Huffman coding.
-spec encode(binary()) -> binary().
encode(Data) ->
    Bits = encode_bits(Data, <<>>),
    BitSize = bit_size(Bits),
    %% Pad with 1s to byte boundary (RFC 7541 Section 5.2)
    Padding = (8 - (BitSize rem 8)) rem 8,
    PaddingBits = (1 bsl Padding) - 1,
    <<Bits/bitstring, PaddingBits:Padding>>.

%% @doc Decode a Huffman-encoded binary string.
-spec decode(binary()) -> {ok, binary()} | {error, huffman_error()}.
decode(Data) ->
    try
        Decoded = decode_bits(Data, <<>>),
        {ok, Decoded}
    catch
        throw:{huffman_error, Reason} ->
            {error, {huffman_decode_error, Reason}}
    end.

%%====================================================================
%% Internal functions - Encoding
%%====================================================================

-spec encode_bits(binary(), bitstring()) -> bitstring().
encode_bits(<<>>, Acc) ->
    Acc;
encode_bits(<<Char:8, Rest/binary>>, Acc) ->
    {Code, Len} = huffman_code(Char),
    encode_bits(Rest, <<Acc/bitstring, Code:Len>>).

%%====================================================================
%% Huffman Code Table (RFC 7541 Appendix B)
%%====================================================================

huffman_code(0) ->
    {16#1ff8, 13};
huffman_code(1) ->
    {16#7fffd8, 23};
huffman_code(2) ->
    {16#fffffe2, 28};
huffman_code(3) ->
    {16#fffffe3, 28};
huffman_code(4) ->
    {16#fffffe4, 28};
huffman_code(5) ->
    {16#fffffe5, 28};
huffman_code(6) ->
    {16#fffffe6, 28};
huffman_code(7) ->
    {16#fffffe7, 28};
huffman_code(8) ->
    {16#fffffe8, 28};
huffman_code(9) ->
    {16#ffffea, 24};
huffman_code(10) ->
    {16#3ffffffc, 30};
huffman_code(11) ->
    {16#fffffe9, 28};
huffman_code(12) ->
    {16#fffffea, 28};
huffman_code(13) ->
    {16#3ffffffd, 30};
huffman_code(14) ->
    {16#fffffeb, 28};
huffman_code(15) ->
    {16#fffffec, 28};
huffman_code(16) ->
    {16#fffffed, 28};
huffman_code(17) ->
    {16#fffffee, 28};
huffman_code(18) ->
    {16#fffffef, 28};
huffman_code(19) ->
    {16#ffffff0, 28};
huffman_code(20) ->
    {16#ffffff1, 28};
huffman_code(21) ->
    {16#ffffff2, 28};
huffman_code(22) ->
    {16#3ffffffe, 30};
huffman_code(23) ->
    {16#ffffff3, 28};
huffman_code(24) ->
    {16#ffffff4, 28};
huffman_code(25) ->
    {16#ffffff5, 28};
huffman_code(26) ->
    {16#ffffff6, 28};
huffman_code(27) ->
    {16#ffffff7, 28};
huffman_code(28) ->
    {16#ffffff8, 28};
huffman_code(29) ->
    {16#ffffff9, 28};
huffman_code(30) ->
    {16#ffffffa, 28};
huffman_code(31) ->
    {16#ffffffb, 28};
huffman_code(32) ->
    {16#14, 6};
huffman_code(33) ->
    {16#3f8, 10};
huffman_code(34) ->
    {16#3f9, 10};
huffman_code(35) ->
    {16#ffa, 12};
huffman_code(36) ->
    {16#1ff9, 13};
huffman_code(37) ->
    {16#15, 6};
huffman_code(38) ->
    {16#f8, 8};
huffman_code(39) ->
    {16#7fa, 11};
huffman_code(40) ->
    {16#3fa, 10};
huffman_code(41) ->
    {16#3fb, 10};
huffman_code(42) ->
    {16#f9, 8};
huffman_code(43) ->
    {16#7fb, 11};
huffman_code(44) ->
    {16#fa, 8};
huffman_code(45) ->
    {16#16, 6};
huffman_code(46) ->
    {16#17, 6};
huffman_code(47) ->
    {16#18, 6};
huffman_code(48) ->
    {16#0, 5};
huffman_code(49) ->
    {16#1, 5};
huffman_code(50) ->
    {16#2, 5};
huffman_code(51) ->
    {16#19, 6};
huffman_code(52) ->
    {16#1a, 6};
huffman_code(53) ->
    {16#1b, 6};
huffman_code(54) ->
    {16#1c, 6};
huffman_code(55) ->
    {16#1d, 6};
huffman_code(56) ->
    {16#1e, 6};
huffman_code(57) ->
    {16#1f, 6};
huffman_code(58) ->
    {16#5c, 7};
huffman_code(59) ->
    {16#fb, 8};
huffman_code(60) ->
    {16#7ffc, 15};
huffman_code(61) ->
    {16#20, 6};
huffman_code(62) ->
    {16#ffb, 12};
huffman_code(63) ->
    {16#3fc, 10};
huffman_code(64) ->
    {16#1ffa, 13};
huffman_code(65) ->
    {16#21, 6};
huffman_code(66) ->
    {16#5d, 7};
huffman_code(67) ->
    {16#5e, 7};
huffman_code(68) ->
    {16#5f, 7};
huffman_code(69) ->
    {16#60, 7};
huffman_code(70) ->
    {16#61, 7};
huffman_code(71) ->
    {16#62, 7};
huffman_code(72) ->
    {16#63, 7};
huffman_code(73) ->
    {16#64, 7};
huffman_code(74) ->
    {16#65, 7};
huffman_code(75) ->
    {16#66, 7};
huffman_code(76) ->
    {16#67, 7};
huffman_code(77) ->
    {16#68, 7};
huffman_code(78) ->
    {16#69, 7};
huffman_code(79) ->
    {16#6a, 7};
huffman_code(80) ->
    {16#6b, 7};
huffman_code(81) ->
    {16#6c, 7};
huffman_code(82) ->
    {16#6d, 7};
huffman_code(83) ->
    {16#6e, 7};
huffman_code(84) ->
    {16#6f, 7};
huffman_code(85) ->
    {16#70, 7};
huffman_code(86) ->
    {16#71, 7};
huffman_code(87) ->
    {16#72, 7};
huffman_code(88) ->
    {16#fc, 8};
huffman_code(89) ->
    {16#73, 7};
huffman_code(90) ->
    {16#fd, 8};
huffman_code(91) ->
    {16#1ffb, 13};
huffman_code(92) ->
    {16#7fff0, 19};
huffman_code(93) ->
    {16#1ffc, 13};
huffman_code(94) ->
    {16#3ffc, 14};
huffman_code(95) ->
    {16#22, 6};
huffman_code(96) ->
    {16#7ffd, 15};
huffman_code(97) ->
    {16#3, 5};
huffman_code(98) ->
    {16#23, 6};
huffman_code(99) ->
    {16#4, 5};
huffman_code(100) ->
    {16#24, 6};
huffman_code(101) ->
    {16#5, 5};
huffman_code(102) ->
    {16#25, 6};
huffman_code(103) ->
    {16#26, 6};
huffman_code(104) ->
    {16#27, 6};
huffman_code(105) ->
    {16#6, 5};
huffman_code(106) ->
    {16#74, 7};
huffman_code(107) ->
    {16#75, 7};
huffman_code(108) ->
    {16#28, 6};
huffman_code(109) ->
    {16#29, 6};
huffman_code(110) ->
    {16#2a, 6};
huffman_code(111) ->
    {16#7, 5};
huffman_code(112) ->
    {16#2b, 6};
huffman_code(113) ->
    {16#76, 7};
huffman_code(114) ->
    {16#2c, 6};
huffman_code(115) ->
    {16#8, 5};
huffman_code(116) ->
    {16#9, 5};
huffman_code(117) ->
    {16#2d, 6};
huffman_code(118) ->
    {16#77, 7};
huffman_code(119) ->
    {16#78, 7};
huffman_code(120) ->
    {16#79, 7};
huffman_code(121) ->
    {16#7a, 7};
huffman_code(122) ->
    {16#7b, 7};
huffman_code(123) ->
    {16#7ffe, 15};
huffman_code(124) ->
    {16#7fc, 11};
huffman_code(125) ->
    {16#3ffd, 14};
huffman_code(126) ->
    {16#1ffd, 13};
huffman_code(127) ->
    {16#ffffffc, 28};
huffman_code(128) ->
    {16#fffe6, 20};
huffman_code(129) ->
    {16#3fffd2, 22};
huffman_code(130) ->
    {16#fffe7, 20};
huffman_code(131) ->
    {16#fffe8, 20};
huffman_code(132) ->
    {16#3fffd3, 22};
huffman_code(133) ->
    {16#3fffd4, 22};
huffman_code(134) ->
    {16#3fffd5, 22};
huffman_code(135) ->
    {16#7fffd9, 23};
huffman_code(136) ->
    {16#3fffd6, 22};
huffman_code(137) ->
    {16#7fffda, 23};
huffman_code(138) ->
    {16#7fffdb, 23};
huffman_code(139) ->
    {16#7fffdc, 23};
huffman_code(140) ->
    {16#7fffdd, 23};
huffman_code(141) ->
    {16#7fffde, 23};
huffman_code(142) ->
    {16#ffffeb, 24};
huffman_code(143) ->
    {16#7fffdf, 23};
huffman_code(144) ->
    {16#ffffec, 24};
huffman_code(145) ->
    {16#ffffed, 24};
huffman_code(146) ->
    {16#3fffd7, 22};
huffman_code(147) ->
    {16#7fffe0, 23};
huffman_code(148) ->
    {16#ffffee, 24};
huffman_code(149) ->
    {16#7fffe1, 23};
huffman_code(150) ->
    {16#7fffe2, 23};
huffman_code(151) ->
    {16#7fffe3, 23};
huffman_code(152) ->
    {16#7fffe4, 23};
huffman_code(153) ->
    {16#1fffdc, 21};
huffman_code(154) ->
    {16#3fffd8, 22};
huffman_code(155) ->
    {16#7fffe5, 23};
huffman_code(156) ->
    {16#3fffd9, 22};
huffman_code(157) ->
    {16#7fffe6, 23};
huffman_code(158) ->
    {16#7fffe7, 23};
huffman_code(159) ->
    {16#ffffef, 24};
huffman_code(160) ->
    {16#3fffda, 22};
huffman_code(161) ->
    {16#1fffdd, 21};
huffman_code(162) ->
    {16#fffe9, 20};
huffman_code(163) ->
    {16#3fffdb, 22};
huffman_code(164) ->
    {16#3fffdc, 22};
huffman_code(165) ->
    {16#7fffe8, 23};
huffman_code(166) ->
    {16#7fffe9, 23};
huffman_code(167) ->
    {16#1fffde, 21};
huffman_code(168) ->
    {16#7fffea, 23};
huffman_code(169) ->
    {16#3fffdd, 22};
huffman_code(170) ->
    {16#3fffde, 22};
huffman_code(171) ->
    {16#fffff0, 24};
huffman_code(172) ->
    {16#1fffdf, 21};
huffman_code(173) ->
    {16#3fffdf, 22};
huffman_code(174) ->
    {16#7fffeb, 23};
huffman_code(175) ->
    {16#7fffec, 23};
huffman_code(176) ->
    {16#1fffe0, 21};
huffman_code(177) ->
    {16#1fffe1, 21};
huffman_code(178) ->
    {16#3fffe0, 22};
huffman_code(179) ->
    {16#1fffe2, 21};
huffman_code(180) ->
    {16#7fffed, 23};
huffman_code(181) ->
    {16#3fffe1, 22};
huffman_code(182) ->
    {16#7fffee, 23};
huffman_code(183) ->
    {16#7fffef, 23};
huffman_code(184) ->
    {16#fffea, 20};
huffman_code(185) ->
    {16#3fffe2, 22};
huffman_code(186) ->
    {16#3fffe3, 22};
huffman_code(187) ->
    {16#3fffe4, 22};
huffman_code(188) ->
    {16#7ffff0, 23};
huffman_code(189) ->
    {16#3fffe5, 22};
huffman_code(190) ->
    {16#3fffe6, 22};
huffman_code(191) ->
    {16#7ffff1, 23};
huffman_code(192) ->
    {16#3ffffe0, 26};
huffman_code(193) ->
    {16#3ffffe1, 26};
huffman_code(194) ->
    {16#fffeb, 20};
huffman_code(195) ->
    {16#7fff1, 19};
huffman_code(196) ->
    {16#3fffe7, 22};
huffman_code(197) ->
    {16#7ffff2, 23};
huffman_code(198) ->
    {16#3fffe8, 22};
huffman_code(199) ->
    {16#1ffffec, 25};
huffman_code(200) ->
    {16#3ffffe2, 26};
huffman_code(201) ->
    {16#3ffffe3, 26};
huffman_code(202) ->
    {16#3ffffe4, 26};
huffman_code(203) ->
    {16#7ffffde, 27};
huffman_code(204) ->
    {16#7ffffdf, 27};
huffman_code(205) ->
    {16#3ffffe5, 26};
huffman_code(206) ->
    {16#fffff1, 24};
huffman_code(207) ->
    {16#1ffffed, 25};
huffman_code(208) ->
    {16#7fff2, 19};
huffman_code(209) ->
    {16#1fffe3, 21};
huffman_code(210) ->
    {16#3ffffe6, 26};
huffman_code(211) ->
    {16#7ffffe0, 27};
huffman_code(212) ->
    {16#7ffffe1, 27};
huffman_code(213) ->
    {16#3ffffe7, 26};
huffman_code(214) ->
    {16#7ffffe2, 27};
huffman_code(215) ->
    {16#fffff2, 24};
huffman_code(216) ->
    {16#1fffe4, 21};
huffman_code(217) ->
    {16#1fffe5, 21};
huffman_code(218) ->
    {16#3ffffe8, 26};
huffman_code(219) ->
    {16#3ffffe9, 26};
huffman_code(220) ->
    {16#ffffffd, 28};
huffman_code(221) ->
    {16#7ffffe3, 27};
huffman_code(222) ->
    {16#7ffffe4, 27};
huffman_code(223) ->
    {16#7ffffe5, 27};
huffman_code(224) ->
    {16#fffec, 20};
huffman_code(225) ->
    {16#fffff3, 24};
huffman_code(226) ->
    {16#fffed, 20};
huffman_code(227) ->
    {16#1fffe6, 21};
huffman_code(228) ->
    {16#3fffe9, 22};
huffman_code(229) ->
    {16#1fffe7, 21};
huffman_code(230) ->
    {16#1fffe8, 21};
huffman_code(231) ->
    {16#7ffff3, 23};
huffman_code(232) ->
    {16#3fffea, 22};
huffman_code(233) ->
    {16#3fffeb, 22};
huffman_code(234) ->
    {16#1ffffee, 25};
huffman_code(235) ->
    {16#1ffffef, 25};
huffman_code(236) ->
    {16#fffff4, 24};
huffman_code(237) ->
    {16#fffff5, 24};
huffman_code(238) ->
    {16#3ffffea, 26};
huffman_code(239) ->
    {16#7ffff4, 23};
huffman_code(240) ->
    {16#3ffffeb, 26};
huffman_code(241) ->
    {16#7ffffe6, 27};
huffman_code(242) ->
    {16#3ffffec, 26};
huffman_code(243) ->
    {16#3ffffed, 26};
huffman_code(244) ->
    {16#7ffffe7, 27};
huffman_code(245) ->
    {16#7ffffe8, 27};
huffman_code(246) ->
    {16#7ffffe9, 27};
huffman_code(247) ->
    {16#7ffffea, 27};
huffman_code(248) ->
    {16#7ffffeb, 27};
huffman_code(249) ->
    {16#ffffffe, 28};
huffman_code(250) ->
    {16#7ffffec, 27};
huffman_code(251) ->
    {16#7ffffed, 27};
huffman_code(252) ->
    {16#7ffffee, 27};
huffman_code(253) ->
    {16#7ffffef, 27};
huffman_code(254) ->
    {16#7fffff0, 27};
huffman_code(255) ->
    {16#3ffffee, 26}.

%%====================================================================
%% Internal functions - Decoding (Direct Pattern Matching)
%%====================================================================

-spec decode_bits(binary(), binary()) -> binary().
decode_bits(<<16#3ffffffe:30, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 22>>);
decode_bits(<<16#3ffffffd:30, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 13>>);
decode_bits(<<16#3ffffffc:30, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 10>>);
decode_bits(<<16#ffffffe:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 249>>);
decode_bits(<<16#ffffffd:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 220>>);
decode_bits(<<16#ffffffc:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 127>>);
decode_bits(<<16#ffffffb:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 31>>);
decode_bits(<<16#ffffffa:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 30>>);
decode_bits(<<16#ffffff9:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 29>>);
decode_bits(<<16#ffffff8:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 28>>);
decode_bits(<<16#ffffff7:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 27>>);
decode_bits(<<16#ffffff6:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 26>>);
decode_bits(<<16#ffffff5:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 25>>);
decode_bits(<<16#ffffff4:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 24>>);
decode_bits(<<16#ffffff3:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 23>>);
decode_bits(<<16#ffffff2:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 21>>);
decode_bits(<<16#ffffff1:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 20>>);
decode_bits(<<16#ffffff0:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 19>>);
decode_bits(<<16#fffffef:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 18>>);
decode_bits(<<16#fffffee:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 17>>);
decode_bits(<<16#fffffed:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 16>>);
decode_bits(<<16#fffffec:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 15>>);
decode_bits(<<16#fffffeb:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 14>>);
decode_bits(<<16#fffffea:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 12>>);
decode_bits(<<16#fffffe9:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 11>>);
decode_bits(<<16#fffffe8:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 8>>);
decode_bits(<<16#fffffe7:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 7>>);
decode_bits(<<16#fffffe6:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 6>>);
decode_bits(<<16#fffffe5:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 5>>);
decode_bits(<<16#fffffe4:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 4>>);
decode_bits(<<16#fffffe3:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 3>>);
decode_bits(<<16#fffffe2:28, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 2>>);
decode_bits(<<16#7fffff0:27, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 254>>);
decode_bits(<<16#7ffffef:27, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 253>>);
decode_bits(<<16#7ffffee:27, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 252>>);
decode_bits(<<16#7ffffed:27, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 251>>);
decode_bits(<<16#7ffffec:27, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 250>>);
decode_bits(<<16#7ffffeb:27, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 248>>);
decode_bits(<<16#7ffffea:27, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 247>>);
decode_bits(<<16#7ffffe9:27, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 246>>);
decode_bits(<<16#7ffffe8:27, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 245>>);
decode_bits(<<16#7ffffe7:27, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 244>>);
decode_bits(<<16#7ffffe6:27, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 241>>);
decode_bits(<<16#7ffffe5:27, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 223>>);
decode_bits(<<16#7ffffe4:27, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 222>>);
decode_bits(<<16#7ffffe3:27, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 221>>);
decode_bits(<<16#7ffffe2:27, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 214>>);
decode_bits(<<16#7ffffe1:27, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 212>>);
decode_bits(<<16#7ffffe0:27, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 211>>);
decode_bits(<<16#7ffffdf:27, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 204>>);
decode_bits(<<16#7ffffde:27, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 203>>);
decode_bits(<<16#3ffffee:26, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 255>>);
decode_bits(<<16#3ffffed:26, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 243>>);
decode_bits(<<16#3ffffec:26, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 242>>);
decode_bits(<<16#3ffffeb:26, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 240>>);
decode_bits(<<16#3ffffea:26, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 238>>);
decode_bits(<<16#3ffffe9:26, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 219>>);
decode_bits(<<16#3ffffe8:26, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 218>>);
decode_bits(<<16#3ffffe7:26, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 213>>);
decode_bits(<<16#3ffffe6:26, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 210>>);
decode_bits(<<16#3ffffe5:26, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 205>>);
decode_bits(<<16#3ffffe4:26, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 202>>);
decode_bits(<<16#3ffffe3:26, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 201>>);
decode_bits(<<16#3ffffe2:26, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 200>>);
decode_bits(<<16#3ffffe1:26, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 193>>);
decode_bits(<<16#3ffffe0:26, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 192>>);
decode_bits(<<16#1ffffef:25, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 235>>);
decode_bits(<<16#1ffffee:25, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 234>>);
decode_bits(<<16#1ffffed:25, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 207>>);
decode_bits(<<16#1ffffec:25, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 199>>);
decode_bits(<<16#fffff5:24, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 237>>);
decode_bits(<<16#fffff4:24, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 236>>);
decode_bits(<<16#fffff3:24, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 225>>);
decode_bits(<<16#fffff2:24, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 215>>);
decode_bits(<<16#fffff1:24, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 206>>);
decode_bits(<<16#fffff0:24, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 171>>);
decode_bits(<<16#ffffef:24, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 159>>);
decode_bits(<<16#ffffee:24, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 148>>);
decode_bits(<<16#ffffed:24, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 145>>);
decode_bits(<<16#ffffec:24, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 144>>);
decode_bits(<<16#ffffeb:24, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 142>>);
decode_bits(<<16#ffffea:24, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 9>>);
decode_bits(<<16#7ffff4:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 239>>);
decode_bits(<<16#7ffff3:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 231>>);
decode_bits(<<16#7ffff2:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 197>>);
decode_bits(<<16#7ffff1:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 191>>);
decode_bits(<<16#7ffff0:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 188>>);
decode_bits(<<16#7fffef:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 183>>);
decode_bits(<<16#7fffee:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 182>>);
decode_bits(<<16#7fffed:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 180>>);
decode_bits(<<16#7fffec:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 175>>);
decode_bits(<<16#7fffeb:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 174>>);
decode_bits(<<16#7fffea:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 168>>);
decode_bits(<<16#7fffe9:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 166>>);
decode_bits(<<16#7fffe8:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 165>>);
decode_bits(<<16#7fffe7:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 158>>);
decode_bits(<<16#7fffe6:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 157>>);
decode_bits(<<16#7fffe5:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 155>>);
decode_bits(<<16#7fffe4:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 152>>);
decode_bits(<<16#7fffe3:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 151>>);
decode_bits(<<16#7fffe2:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 150>>);
decode_bits(<<16#7fffe1:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 149>>);
decode_bits(<<16#7fffe0:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 147>>);
decode_bits(<<16#7fffdf:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 143>>);
decode_bits(<<16#7fffde:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 141>>);
decode_bits(<<16#7fffdd:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 140>>);
decode_bits(<<16#7fffdc:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 139>>);
decode_bits(<<16#7fffdb:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 138>>);
decode_bits(<<16#7fffda:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 137>>);
decode_bits(<<16#7fffd9:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 135>>);
decode_bits(<<16#7fffd8:23, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 1>>);
decode_bits(<<16#3fffeb:22, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 233>>);
decode_bits(<<16#3fffea:22, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 232>>);
decode_bits(<<16#3fffe9:22, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 228>>);
decode_bits(<<16#3fffe8:22, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 198>>);
decode_bits(<<16#3fffe7:22, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 196>>);
decode_bits(<<16#3fffe6:22, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 190>>);
decode_bits(<<16#3fffe5:22, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 189>>);
decode_bits(<<16#3fffe4:22, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 187>>);
decode_bits(<<16#3fffe3:22, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 186>>);
decode_bits(<<16#3fffe2:22, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 185>>);
decode_bits(<<16#3fffe1:22, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 181>>);
decode_bits(<<16#3fffe0:22, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 178>>);
decode_bits(<<16#3fffdf:22, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 173>>);
decode_bits(<<16#3fffde:22, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 170>>);
decode_bits(<<16#3fffdd:22, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 169>>);
decode_bits(<<16#3fffdc:22, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 164>>);
decode_bits(<<16#3fffdb:22, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 163>>);
decode_bits(<<16#3fffda:22, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 160>>);
decode_bits(<<16#3fffd9:22, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 156>>);
decode_bits(<<16#3fffd8:22, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 154>>);
decode_bits(<<16#3fffd7:22, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 146>>);
decode_bits(<<16#3fffd6:22, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 136>>);
decode_bits(<<16#3fffd5:22, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 134>>);
decode_bits(<<16#3fffd4:22, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 133>>);
decode_bits(<<16#3fffd3:22, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 132>>);
decode_bits(<<16#3fffd2:22, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 129>>);
decode_bits(<<16#1fffe8:21, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 230>>);
decode_bits(<<16#1fffe7:21, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 229>>);
decode_bits(<<16#1fffe6:21, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 227>>);
decode_bits(<<16#1fffe5:21, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 217>>);
decode_bits(<<16#1fffe4:21, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 216>>);
decode_bits(<<16#1fffe3:21, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 209>>);
decode_bits(<<16#1fffe2:21, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 179>>);
decode_bits(<<16#1fffe1:21, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 177>>);
decode_bits(<<16#1fffe0:21, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 176>>);
decode_bits(<<16#1fffdf:21, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 172>>);
decode_bits(<<16#1fffde:21, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 167>>);
decode_bits(<<16#1fffdd:21, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 161>>);
decode_bits(<<16#1fffdc:21, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 153>>);
decode_bits(<<16#fffed:20, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 226>>);
decode_bits(<<16#fffec:20, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 224>>);
decode_bits(<<16#fffeb:20, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 194>>);
decode_bits(<<16#fffea:20, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 184>>);
decode_bits(<<16#fffe9:20, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 162>>);
decode_bits(<<16#fffe8:20, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 131>>);
decode_bits(<<16#fffe7:20, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 130>>);
decode_bits(<<16#fffe6:20, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 128>>);
decode_bits(<<16#7fff2:19, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 208>>);
decode_bits(<<16#7fff1:19, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 195>>);
decode_bits(<<16#7fff0:19, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 92>>);
decode_bits(<<16#7ffe:15, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 123>>);
decode_bits(<<16#7ffd:15, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 96>>);
decode_bits(<<16#7ffc:15, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 60>>);
decode_bits(<<16#3ffd:14, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 125>>);
decode_bits(<<16#3ffc:14, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 94>>);
decode_bits(<<16#1ffd:13, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 126>>);
decode_bits(<<16#1ffc:13, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 93>>);
decode_bits(<<16#1ffb:13, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 91>>);
decode_bits(<<16#1ffa:13, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 64>>);
decode_bits(<<16#1ff9:13, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 36>>);
decode_bits(<<16#1ff8:13, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 0>>);
decode_bits(<<16#ffb:12, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 62>>);
decode_bits(<<16#ffa:12, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 35>>);
decode_bits(<<16#7fc:11, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 124>>);
decode_bits(<<16#7fb:11, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 43>>);
decode_bits(<<16#7fa:11, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 39>>);
decode_bits(<<16#3fc:10, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 63>>);
decode_bits(<<16#3fb:10, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 41>>);
decode_bits(<<16#3fa:10, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 40>>);
decode_bits(<<16#3f9:10, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 34>>);
decode_bits(<<16#3f8:10, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 33>>);
decode_bits(<<16#fd:8, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 90>>);
decode_bits(<<16#fc:8, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 88>>);
decode_bits(<<16#fb:8, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 59>>);
decode_bits(<<16#fa:8, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 44>>);
decode_bits(<<16#f9:8, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 42>>);
decode_bits(<<16#f8:8, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 38>>);
decode_bits(<<16#7b:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 122>>);
decode_bits(<<16#7a:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 121>>);
decode_bits(<<16#79:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 120>>);
decode_bits(<<16#78:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 119>>);
decode_bits(<<16#77:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 118>>);
decode_bits(<<16#76:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 113>>);
decode_bits(<<16#75:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 107>>);
decode_bits(<<16#74:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 106>>);
decode_bits(<<16#73:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 89>>);
decode_bits(<<16#72:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 87>>);
decode_bits(<<16#71:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 86>>);
decode_bits(<<16#70:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 85>>);
decode_bits(<<16#6f:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 84>>);
decode_bits(<<16#6e:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 83>>);
decode_bits(<<16#6d:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 82>>);
decode_bits(<<16#6c:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 81>>);
decode_bits(<<16#6b:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 80>>);
decode_bits(<<16#6a:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 79>>);
decode_bits(<<16#69:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 78>>);
decode_bits(<<16#68:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 77>>);
decode_bits(<<16#67:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 76>>);
decode_bits(<<16#66:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 75>>);
decode_bits(<<16#65:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 74>>);
decode_bits(<<16#64:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 73>>);
decode_bits(<<16#63:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 72>>);
decode_bits(<<16#62:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 71>>);
decode_bits(<<16#61:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 70>>);
decode_bits(<<16#60:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 69>>);
decode_bits(<<16#5f:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 68>>);
decode_bits(<<16#5e:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 67>>);
decode_bits(<<16#5d:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 66>>);
decode_bits(<<16#5c:7, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 58>>);
decode_bits(<<16#2d:6, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 117>>);
decode_bits(<<16#2c:6, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 114>>);
decode_bits(<<16#2b:6, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 112>>);
decode_bits(<<16#2a:6, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 110>>);
decode_bits(<<16#29:6, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 109>>);
decode_bits(<<16#28:6, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 108>>);
decode_bits(<<16#27:6, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 104>>);
decode_bits(<<16#26:6, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 103>>);
decode_bits(<<16#25:6, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 102>>);
decode_bits(<<16#24:6, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 100>>);
decode_bits(<<16#23:6, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 98>>);
decode_bits(<<16#22:6, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 95>>);
decode_bits(<<16#21:6, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 65>>);
decode_bits(<<16#20:6, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 61>>);
decode_bits(<<16#1f:6, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 57>>);
decode_bits(<<16#1e:6, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 56>>);
decode_bits(<<16#1d:6, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 55>>);
decode_bits(<<16#1c:6, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 54>>);
decode_bits(<<16#1b:6, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 53>>);
decode_bits(<<16#1a:6, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 52>>);
decode_bits(<<16#19:6, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 51>>);
decode_bits(<<16#18:6, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 47>>);
decode_bits(<<16#17:6, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 46>>);
decode_bits(<<16#16:6, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 45>>);
decode_bits(<<16#15:6, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 37>>);
decode_bits(<<16#14:6, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 32>>);
decode_bits(<<16#9:5, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 116>>);
decode_bits(<<16#8:5, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 115>>);
decode_bits(<<16#7:5, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 111>>);
decode_bits(<<16#6:5, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 105>>);
decode_bits(<<16#5:5, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 101>>);
decode_bits(<<16#4:5, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 99>>);
decode_bits(<<16#3:5, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 97>>);
decode_bits(<<16#2:5, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 50>>);
decode_bits(<<16#1:5, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 49>>);
decode_bits(<<16#0:5, Rest/bitstring>>, Acc) ->
    decode_bits(Rest, <<Acc/binary, 48>>);
decode_bits(<<>>, Acc) ->
    Acc;
decode_bits(Padding, Acc) when bit_size(Padding) >= 1, bit_size(Padding) =< 7 ->
    PaddingSize = bit_size(Padding),
    AllOnes = (1 bsl PaddingSize) - 1,
    <<PaddingInt:PaddingSize>> = Padding,
    case PaddingInt of
        AllOnes -> Acc;
        _ -> throw({huffman_error, <<"invalid_padding">>})
    end;
decode_bits(_Data, _Acc) ->
    throw({huffman_error, <<"invalid_huffman_code">>}).

%%====================================================================
%% Unit Tests
%%====================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Test cases
%%====================================================================

encode_decode_roundtrip_test() ->
    %% Test round-trip encoding/decoding of common strings
    Strings = [
        <<"www.example.com">>,
        <<"no-cache">>,
        <<"custom-key">>,
        <<"custom-value">>,
        <<"">>,
        <<"a">>,
        <<"test">>,
        <<"HTTP/2">>,
        <<"gzip, deflate">>,
        <<"content-type">>,
        <<"application/json">>
    ],

    lists:foreach(
        fun(String) ->
            Encoded = gen_http_parser_huffman:encode(String),
            ?assertMatch({ok, String}, gen_http_parser_huffman:decode(Encoded))
        end,
        Strings
    ).

encode_empty_test() ->
    %% Encoding empty string should work
    Encoded = gen_http_parser_huffman:encode(<<>>),
    ?assert(is_binary(Encoded)).

encode_common_headers_test() ->
    %% Test encoding of common HTTP header names
    Headers = [
        <<"content-length">>,
        <<"content-type">>,
        <<"accept">>,
        <<"accept-encoding">>,
        <<"authorization">>,
        <<"cache-control">>,
        <<"cookie">>,
        <<"host">>,
        <<"user-agent">>
    ],

    lists:foreach(
        fun(Header) ->
            Encoded = gen_http_parser_huffman:encode(Header),
            ?assert(is_binary(Encoded)),
            ?assertMatch({ok, Header}, gen_http_parser_huffman:decode(Encoded))
        end,
        Headers
    ).

encode_alphanumeric_test() ->
    Data = <<"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789">>,
    Encoded = gen_http_parser_huffman:encode(Data),
    ?assertMatch({ok, Data}, gen_http_parser_huffman:decode(Encoded)).

encode_special_chars_test() ->
    Data = <<"/:.-_=&?">>,
    Encoded = gen_http_parser_huffman:encode(Data),
    ?assertMatch({ok, Data}, gen_http_parser_huffman:decode(Encoded)).

rfc_test_vector_custom_key_test() ->
    Data = <<"custom-key">>,
    Encoded = gen_http_parser_huffman:encode(Data),
    ?assertMatch({ok, <<"custom-key">>}, gen_http_parser_huffman:decode(Encoded)),
    ?assert(byte_size(Encoded) =< 10).

compression_ratio_test() ->
    LongString = <<"content-encoding-gzip-deflate-br-content-type-application-json">>,
    Encoded = gen_http_parser_huffman:encode(LongString),
    ?assertMatch({ok, LongString}, gen_http_parser_huffman:decode(Encoded)),
    OriginalSize = byte_size(LongString),
    EncodedSize = byte_size(Encoded),
    CompressionRatio = EncodedSize / OriginalSize,
    ?assert(CompressionRatio < 0.9).

padding_test() ->
    lists:foreach(
        fun(N) ->
            Data = binary:copy(<<"a">>, N),
            Encoded = gen_http_parser_huffman:encode(Data),
            ?assertEqual(0, bit_size(Encoded) rem 8),
            ?assertMatch({ok, Data}, gen_http_parser_huffman:decode(Encoded))
        end,
        lists:seq(1, 20)
    ).

decode_invalid_test() ->
    %% Decoding invalid data should return error
    InvalidData = <<16#FF, 16#FF, 16#FF, 16#FF>>,
    Result = gen_http_parser_huffman:decode(InvalidData),
    ?assertMatch({error, _}, Result).

high_bit_characters_test() ->
    Data = <<200, 201, 202>>,
    Encoded = gen_http_parser_huffman:encode(Data),
    ?assertMatch({ok, Data}, gen_http_parser_huffman:decode(Encoded)).

-endif.
