import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:cryptography/cryptography.dart' as dc;
import 'package:pinenacl/tweetnacl.dart';
import 'package:pinenacl/x25519.dart' as x;
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/key_derivators/hkdf.dart';
import 'package:pointycastle/pointycastle.dart' show HkdfParameters;
import 'package:wallet_connect_v2/apis/core/crypto/crypto_models.dart';
import 'package:wallet_connect_v2/apis/models/models.dart';
// import 'package:x25519/x25519.dart' as x2;

class CryptoUtils {
  static final _random = Random.secure();

  static const BASE10 = 'base10';
  static const BASE16 = 'base16';
  static const BASE64 = 'baes64';

  static const IV_LENGTH = 12;
  static const KEY_LENGTH = 32;

  static const TYPE_LENGTH = 1;
  static const TYPE_0 = 0;
  static const TYPE_1 = 1;

  static KeyPair generateKeyPair() {
    x.PrivateKey pk = x.PrivateKey.generate();
    // final PrivateKey pk = PrivateKey.generate();

    return KeyPair(
      hex.encode(pk.toList()),
      hex.encode(pk.publicKey.toList()),
    );

    // final x.KeyPair keyPair = x.generateKeyPair();
    // return KeyPair(
    //   hex.encode(keyPair.privateKey),
    //   hex.encode(keyPair.publicKey),
    // );
  }

  static Uint8List randomBytes(int length) {
    final Uint8List random = Uint8List(length);
    for (int i = 0; i < length; i++) {
      random[i] = _random.nextInt(256);
    }
    return random;
  }

  static String generateRandomBytes32() {
    return base64Url.encode(randomBytes(32));
  }

  static Future<String> deriveSymKey(String privKeyA, String pubKeyB) async {
    final Uint8List zeros = Uint8List(KEY_LENGTH);
    final Uint8List sharedKey1 = TweetNaCl.crypto_scalarmult(
      zeros,
      Uint8List.fromList(hex.decode(privKeyA)),
      Uint8List.fromList(hex.decode(pubKeyB)),
    );
    print(sharedKey1);
    // TweetNaCl.crypto_box_beforenm(k, pub, priv);

    Uint8List out = Uint8List(KEY_LENGTH);

    final HKDFKeyDerivator hkdf = HKDFKeyDerivator(SHA256Digest());
    final HkdfParameters params = HkdfParameters(
      sharedKey1,
      KEY_LENGTH,
    );
    hkdf.init(params);
    // final pc.KeyParameter keyParam = hkdf.extract(null, sharedKey1);
    hkdf.deriveKey(null, 0, out, 0);
    return hex.encode(out);
  }

  static String hashKey(String key) {
    return hex.encode(
      SHA256Digest().process(
        Uint8List.fromList(
          hex.decode(key),
        ),
      ),
    );
    // return hex.encode(Hash.sha256(hex.decode(key)));
  }

  static String hashMessage(String message) {
    return hex.encode(
      SHA256Digest().process(
        Uint8List.fromList(
          utf8.encode(message),
        ),
      ),
    );
    // return hex.encode(Hash.sha256(message));
  }

  static Future<String> encrypt(
    String message,
    String symKey, {
    int? type,
    String? iv,
    String? senderPublicKey,
  }) async {
    final int decodedType = type != null ? type : TYPE_0;

    // Check for type 1 envelope, throw an error if data is invalid
    if (decodedType == TYPE_1 && senderPublicKey == null) {
      throw Error(
        -1,
        'Missing sender public key for type 1 envelope',
      );
    }

    // final String senderPublicKey = senderPublicKey !=
    final Uint8List usedIV =
        (iv != null ? hex.decode(iv) : randomBytes(IV_LENGTH)) as Uint8List;

    final chacha = dc.Chacha20.poly1305Aead();
    dc.SecretBox b = await chacha.encrypt(
      utf8.encode(message),
      secretKey: dc.SecretKey(
        hex.decode(symKey),
      ),
      nonce: usedIV,
    );

    return serialize(
      decodedType,
      b.concatenation(),
      usedIV,
      senderPublicKey: senderPublicKey != null
          ? hex.decode(senderPublicKey) as Uint8List
          : null,
    );
  }

  static Future<String> decrypt(String symKey, String encoded) async {
    final chacha = dc.Chacha20.poly1305Aead();
    final dc.SecretKey secretKey = dc.SecretKey(
      hex.decode(symKey),
    );
    final EncodingParams encodedData = deserialize(encoded);
    final dc.SecretBox b = dc.SecretBox.fromConcatenation(
      encodedData.ivSealed,
      nonceLength: 12,
      macLength: 16,
    );
    List<int> data = await chacha.decrypt(b, secretKey: secretKey);
    return utf8.decode(data);
  }

  static String serialize(
    int type,
    Uint8List sealed,
    Uint8List iv, {
    Uint8List? senderPublicKey,
  }) {
    List<int> l = [type];

    if (type == TYPE_1) {
      if (senderPublicKey == null) {
        throw Error(-1, 'Missing sender public key for type 1 envelope');
      }

      l.addAll(senderPublicKey);
    }

    // l.addAll(iv);
    l.addAll(sealed);

    return base64Encode(l);
  }

  static EncodingParams deserialize(String encoded) {
    final Uint8List bytes = base64Decode(encoded);
    final int type = bytes[0];

    int index = TYPE_LENGTH;
    Uint8List? senderPublicKey;
    if (type == TYPE_1) {
      senderPublicKey = bytes.sublist(
        index,
        index + KEY_LENGTH,
      );
      index += KEY_LENGTH;
    }
    Uint8List iv = bytes.sublist(index, index + IV_LENGTH);
    Uint8List ivSealed = bytes.sublist(index);
    index += IV_LENGTH;
    Uint8List sealed = bytes.sublist(index);

    return EncodingParams(
      type,
      sealed,
      iv,
      ivSealed,
      senderPublicKey: senderPublicKey,
    );
  }

  static EncodingValidation validateDecoding(
    String encoded, {
    String? receiverPublicKey,
  }) {
    final EncodingParams deserialized = deserialize(encoded);
    final String? senderPublicKey = deserialized.senderPublicKey != null
        ? hex.encode(deserialized.senderPublicKey!)
        : null;
    return validateEncoding(
      type: deserialized.type,
      senderPublicKey: senderPublicKey,
      receiverPublicKey: receiverPublicKey,
    );
  }

  static EncodingValidation validateEncoding({
    int? type,
    String? senderPublicKey,
    String? receiverPublicKey,
  }) {
    final int t = type != null ? type : TYPE_0;
    if (t == TYPE_1) {
      if (senderPublicKey == null) {
        throw new Error(-1, "Missing sender public key");
      }
      if (receiverPublicKey == null) {
        throw new Error(-1, "Missing receiver public key");
      }
    }
    return EncodingValidation(
      t,
      senderPublicKey: senderPublicKey,
      receiverPublicKey: receiverPublicKey,
    );
  }

  static bool isTypeOneEnvelope(
    EncodingValidation result,
  ) {
    return result.type == TYPE_1 &&
        result.senderPublicKey != null &&
        result.receiverPublicKey != null;
  }
}