module Flock
  # Logical keyboard keys — shared by every backend so game code is portable. Values are
  # SDL physical scancodes (the native backend uses them directly; the web backend maps DOM
  # key codes to these). Read them through `world.resource(Flock::Input)` on any target.
  enum Key : Int32
    A = 4; B = 5; C = 6; D = 7; E = 8; F = 9; G = 10; H = 11; I = 12
    J = 13; K = 14; L = 15; M = 16; N = 17; O = 18; P = 19; Q = 20; R = 21
    S = 22; T = 23; U = 24; V = 25; W = 26; X = 27; Y = 28; Z = 29

    Num1 = 30; Num2 = 31; Num3 = 32; Num4 = 33; Num5 = 34
    Num6 = 35; Num7 = 36; Num8 = 37; Num9 = 38; Num0 = 39

    Return = 40; Escape = 41; Backspace = 42; Tab = 43; Space = 44
    Minus = 45; Equals = 46; LeftBracket = 47; RightBracket = 48
    Comma        = 54; Period = 55; Slash = 56

    F1 = 58; F2 = 59; F3 = 60; F4 = 61; F5 = 62; F6 = 63
    F7 = 64; F8 = 65; F9 = 66; F10 = 67; F11 = 68; F12 = 69

    Right = 79; Left = 80; Down = 81; Up = 82

    LCtrl = 224; LShift = 225; LAlt = 226; LGui  = 227
    RCtrl = 228; RShift = 229; RAlt = 230; RGui = 231
  end
end
