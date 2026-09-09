// Copyright (C) 2026 stierms
// SPDX-License-Identifier: GPL-3.0-or-later
// Replay recorded score alterations; no engine search or tablebases required.
use sfbinpack::{CompressedTrainingDataEntryReader, CompressedTrainingDataEntryWriter};
use std::{collections::BTreeMap, error::Error, fs::{self, File, OpenOptions}, path::Path};

type Result<T> = std::result::Result<T, Box<dyn Error>>;

fn alterations(tb: &Path, anchors: &Path) -> Result<BTreeMap<u64, (i16, i16)>> {
    let mut out = BTreeMap::new();
    for (path, magic, width) in [(tb, b"ZQTBSC1\n", 8), (anchors, b"ZQANCH1\n", 16)] {
        let bytes = fs::read(path)?;
        if bytes.len() < 8 || &bytes[..8] != magic || (bytes.len() - 8) % width != 0 {
            return Err(format!("invalid sidecar: {}", path.display()).into());
        }
        let mut previous = None;
        for record in bytes[8..].chunks_exact(width) {
            let (ordinal, offset) = if width == 8 {
                (u32::from_le_bytes(record[..4].try_into()?) as u64, 4)
            } else {
                (u64::from_le_bytes(record[..8].try_into()?), 8)
            };
            let new = i16::from_le_bytes(record[offset..offset+2].try_into()?);
            let old = i16::from_le_bytes(record[offset+2..offset+4].try_into()?);
            if previous.is_some_and(|p| p >= ordinal) || old == new || ![-10000, 0, 10000].contains(&new) {
                return Err(format!("invalid alteration at {ordinal}").into());
            }
            if out.insert(ordinal, (old, new)).is_some() {
                return Err(format!("duplicate alteration at {ordinal}").into());
            }
            previous = Some(ordinal);
        }
    }
    Ok(out)
}

fn replay(input: &Path, tb: &Path, anchors: &Path, output: &Path) -> Result<()> {
    if output.exists() { return Err("output already exists".into()); }
    let changes = alterations(tb, anchors)?;
    let mut reader = CompressedTrainingDataEntryReader::new(File::open(input)?)?;
    let temporary = output.with_extension("binpack.replay-part");
    let file = OpenOptions::new().write(true).create_new(true).open(&temporary)?;
    let result = (|| -> Result<(u64, usize)> {
        let mut writer = CompressedTrainingDataEntryWriter::new(file)?;
        let mut count = 0u64;
        let mut applied = 0usize;
        while reader.has_next() {
            let mut entry = reader.next();
            if let Some(&(old, new)) = changes.get(&count) {
                if entry.score != old { return Err(format!("old-score mismatch at {count}").into()); }
                entry.score = new;
                applied += 1;
            }
            writer.write_entry(&entry)?;
            count += 1;
        }
        if applied != changes.len() { return Err("unconsumed alterations".into()); }
        drop(writer);
        File::open(&temporary)?.sync_all()?;
        // Creating the final name this way cannot overwrite an existing file.
        fs::hard_link(&temporary, output)?;
        Ok((count, applied))
    })();
    fs::remove_file(&temporary)?;
    let (count, applied) = result?;
    println!("decoded={count} applied={applied}");
    Ok(())
}

fn main() -> Result<()> {
    let args: Vec<_> = std::env::args_os().collect();
    if args.len() != 5 { return Err("usage: zigqueen-data-replay INPUT TB_SIDECAR ANCHOR_SIDECAR OUTPUT".into()); }
    replay(Path::new(&args[1]), Path::new(&args[2]), Path::new(&args[3]), Path::new(&args[4]))
}
