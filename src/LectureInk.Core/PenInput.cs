namespace LectureInk.Core;

public enum InputKind { Mouse, Pen, Touch }

/// <summary>
/// Windows marks mouse messages that really came from a pen or a finger: the "extra info" of the
/// message carries the signature 0xFF515700, with bit 0x80 set for touch.
/// (Microsoft docs: "System Events and Mouse Messages".)
/// </summary>
public static class PenInput
{
    const ulong SignatureMask = 0xFFFFFF00, Signature = 0xFF515700, TouchBit = 0x80;

    public static InputKind Kind(ulong extraInfo) =>
        (extraInfo & SignatureMask) != Signature ? InputKind.Mouse
        : (extraInfo & TouchBit) != 0 ? InputKind.Touch : InputKind.Pen;
}
