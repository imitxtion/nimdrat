import nimcrypto, nimcrypto/sysrand

proc deriveKey*(keyStr: string): seq[byte] =
  # SHA256 hash the key to get 32 bytes
  var ctx: sha256
  var digest: MDigest[256]
  ctx.init()
  ctx.update(keyStr)
  digest = ctx.finish()
  result = @(digest.data)

proc encryptAes256*(data: string, keyStr: string): string =
  let key = deriveKey(keyStr)
  var iv = newSeq[byte](16)
  discard randomBytes(iv)
  
  var ctx: CTR[aes256]
  ctx.init(key, iv)
  
  var ciphertext = newSeq[byte](data.len)
  if data.len > 0:
      ctx.encrypt(cast[seq[byte]](data), ciphertext)
  
  # Result = IV + Ciphertext
  let finalSeq = iv & ciphertext
  result = cast[string](finalSeq)

proc decryptAes256*(data: string, keyStr: string): string =
  if data.len < 16: return ""
  let key = deriveKey(keyStr)
  
  let iv = cast[seq[byte]](data[0..15])
  let ciphertext = cast[seq[byte]](data[16..^1])
  
  var ctx: CTR[aes256]
  ctx.init(key, iv)
  
  var plaintext = newSeq[byte](ciphertext.len)
  if ciphertext.len > 0:
      ctx.decrypt(ciphertext, plaintext)
      
  result = cast[string](plaintext)
