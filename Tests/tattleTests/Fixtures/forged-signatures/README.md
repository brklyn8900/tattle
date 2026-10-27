# Forged signatures

These are two copies of a program that does nothing (`int main(void) { return 0; }`),
each signed with a self-signed code-signing certificate whose subject claims an
Apple-issued kind:

- `forged-software-signing`: CN "Software Signing", the subject of Apple's own programs.
- `forged-developer-id`: CN "Developer ID Application: Example Corp (ABCDE12345)".

Each certificate was imported into a throwaway keychain and the binary signed with
`codesign -s <certificate SHA-1>`. codesign finds an untrusted identity only in a keychain
on the user search list, so the throwaway keychain was on it while signing.

Both pass `codesign --verify` and fail `codesign --verify -R="anchor apple generic"`. The
keys are not in the repository, so changing a file means making a new one the same way.
