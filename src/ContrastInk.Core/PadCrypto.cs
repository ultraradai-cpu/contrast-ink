using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace ContrastInk.Core;

/// <summary>
/// Version 2 of the tablet link (docs/pad-protocol.md): a fresh P-256 key pair per connection, keys derived with
/// the code (which never crosses the network), and every message after the hello sealed with AES-256-GCM.
/// </summary>
public static class PadCrypto
{
    public const byte Challenge = 0x86, Proof = 0x04, Sealed = 0x7F;
    public const string ProofText = "hello";

    public static ECDiffieHellman NewKey() => ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);

    /// <summary>A key from its private part (the test vectors).</summary>
    public static ECDiffieHellman FromPrivate(byte[] d)
    {
        var k = ECDiffieHellman.Create();
        k.ImportParameters(new ECParameters { Curve = ECCurve.NamedCurves.nistP256, D = d });
        return k;
    }

    /// <summary>The public key as 65 bytes: 04, then X and Y (what the other side is sent).</summary>
    public static byte[] PublicPoint(ECDiffieHellman k)
    {
        var p = k.ExportParameters(false).Q;
        return new byte[] { 4 }.Concat(p.X!).Concat(p.Y!).ToArray();
    }

    /// <summary>The other side's public key from its 65 bytes; null when it isn't a point on the curve.</summary>
    public static ECDiffieHellmanPublicKey? ReadPoint(byte[] point)
    {
        if (point.Length != 65 || point[0] != 4) return null;
        try
        {
            using var k = ECDiffieHellman.Create(new ECParameters
            {
                Curve = ECCurve.NamedCurves.nistP256,
                Q = new ECPoint { X = point[1..33], Y = point[33..65] },
            });
            return k.PublicKey;
        }
        catch (CryptographicException) { return null; }
    }

    /// <summary>The two keys: tablet→PC, PC→tablet. A different code gives different keys.</summary>
    public static (byte[] toPc, byte[] toTablet) Keys(ECDiffieHellman own, ECDiffieHellmanPublicKey other, byte[] salt, string code)
    {
        var shared = own.DeriveKeyFromHash(other, HashAlgorithmName.SHA256);   // SHA-256 of the x coordinate
        var keys = HKDF.DeriveKey(HashAlgorithmName.SHA256, shared, 64, salt, Encoding.UTF8.GetBytes("contrastink pad v2 " + code));
        return (keys[..32], keys[32..]);
    }
}

/// <summary>One direction's sealing or opening: AES-256-GCM, nonce = 4 zero bytes and a counter from 1.</summary>
public sealed class PadSeal : IDisposable
{
    readonly AesGcm aes;
    ulong counter;   // sealing: the last one used; opening: the last one accepted

    public PadSeal(byte[] key) { aes = new AesGcm(key, 16); }

    /// <summary>A whole message (header and payload) → the payload of a SEALED message.</summary>
    public byte[] Seal(byte[] message)
    {
        var nonce = new byte[12];
        BinaryPrimitives.WriteUInt64BigEndian(nonce.AsSpan(4), ++counter);
        var output = new byte[12 + message.Length + 16];
        nonce.CopyTo(output, 0);
        aes.Encrypt(nonce, message, output.AsSpan(12, message.Length), output.AsSpan(12 + message.Length, 16));
        return output;
    }

    /// <summary>A SEALED payload → the whole message inside; null when it was altered, sealed with another key
    /// (a wrong code), or replayed.</summary>
    public byte[]? Open(byte[] sealedPayload)
    {
        if (sealedPayload.Length < 12 + 16) return null;
        var nonce = sealedPayload.AsSpan(0, 12);
        if (BinaryPrimitives.ReadUInt32BigEndian(nonce) != 0) return null;
        ulong n = BinaryPrimitives.ReadUInt64BigEndian(nonce[4..]);
        if (n <= counter) return null;
        var message = new byte[sealedPayload.Length - 28];
        try { aes.Decrypt(nonce, sealedPayload.AsSpan(12, message.Length), sealedPayload.AsSpan(12 + message.Length, 16), message); }
        catch (CryptographicException) { return null; }
        counter = n;
        return message;
    }

    public void Dispose() => aes.Dispose();
}
