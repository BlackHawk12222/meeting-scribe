# Crowd noise for the noisy-room test

`crowd_noise_16k.wav` — 184 s, 16 kHz mono, 16-bit. Used only by the self-test
(`Scribe --selftest --suite noisy`); it is **not** shipped inside the app.

- 0–92 s: **PCAFETER** (a busy cafeteria), channel 1
- 92–184 s: **PRESTO** (a university restaurant), channel 1

Each half was RMS-normalised to the same level. Nothing else was changed. The self-test mixes this
noise into the AMI meetings at 10, 5 and 0 dB SNR while it runs (no mixed audio is stored).

## Credit and license

From **DEMAND: Diverse Environments Multichannel Acoustic Noise Database**
by Joachim Thiemann (IRISA-CNRS), Nobutaka Ito (University of Tokyo) and Emmanuel Vincent (Inria).
J. Thiemann, N. Ito, E. Vincent, "The Diverse Environments Multi-channel Acoustic Noise Database
(DEMAND): A database of multichannel environmental noise recordings", Proc. Meetings on Acoustics 19,
035081 (2013). Source: https://zenodo.org/records/1227121 (DOI 10.5281/zenodo.1227121).

The authors license the audio under the **Creative Commons Attribution-ShareAlike 3.0 Unported**
license (https://creativecommons.org/licenses/by-sa/3.0/). (Zenodo's metadata field says CC BY 4.0;
we follow the authors' own, stricter statement.) This trimmed and normalised file is therefore also
released under **CC BY-SA 3.0**. The 16 kHz channel-1 audio was taken from the 4-second segments in
the Hugging Face copy `SPARCO-project/benchmark_DEMAND_noise` (segments 0–22 of each environment,
joined back in order).

The meeting audio (AMI Meeting Corpus, ES2004a/b/c) is CC BY 4.0 — see the main README.
