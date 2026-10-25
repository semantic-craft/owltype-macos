//! Pick-pair transitions (user-dictionary.md §10.2): two words picked back to back often enough become a phrase.

use std::path::Path;

use rusqlite::params;

use super::journal::open_journal;
use crate::error::Result;

/// Pick pairs are transient evidence, not dictionary state; this bounds how much typing history they retain (J:627-628).
pub const MAX_PICK_TRANSITIONS: usize = 20_000;

/// Increment and return the pair's count, pruning the oldest rows past 20000 when a new pair appears (J:623-669).
pub fn record_pick_transition(
    user_db: &Path,
    previous_key: &str,
    previous_value: &str,
    key: &str,
    value: &str,
) -> Result<i64> {
    let journal = open_journal(user_db)?;
    journal.execute_batch("BEGIN IMMEDIATE")?;
    let count: i64 = journal
        .prepare_cached(
            "INSERT INTO pick_transitions(previous_key,previous_value,key,value,count) VALUES(?1,?2,?3,?4,1) ON CONFLICT(previous_key,previous_value,key,value) DO UPDATE SET count=count+1,updated_at=unixepoch() RETURNING count",
        )?
        .query_row(params![previous_key, previous_value, key, value], |row| {
            row.get(0)
        })?;
    // Only a new row can push the table past its cap.
    if count == 1 {
        journal
            .prepare_cached(
                "DELETE FROM pick_transitions WHERE updated_at < (SELECT updated_at FROM pick_transitions ORDER BY updated_at DESC LIMIT 1 OFFSET ?1)",
            )?
            .execute(params![MAX_PICK_TRANSITIONS as i64])?;
    }
    // Any `?` above leaves the transaction to the connection guard's rollback.
    journal.execute_batch("COMMIT")?;
    Ok(count)
}

pub fn clear_pick_transition(
    user_db: &Path,
    previous_key: &str,
    previous_value: &str,
    key: &str,
    value: &str,
) -> Result<()> {
    let journal = open_journal(user_db)?;
    journal
        .prepare_cached(
            "DELETE FROM pick_transitions WHERE previous_key=?1 AND previous_value=?2 AND key=?3 AND value=?4",
        )?
        .execute(params![previous_key, previous_value, key, value])?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::super::journal::test_support::{count, Dir};
    use super::*;

    #[test]
    fn pairs_count_up_and_clear() {
        let dir = Dir::new();
        let journal = dir.journal();
        for expected in 1..=3 {
            assert_eq!(
                record_pick_transition(&journal, "shan", "山", "shui", "水").unwrap(),
                expected
            );
        }
        assert_eq!(
            record_pick_transition(&journal, "shan", "闪", "shui", "水").unwrap(),
            1
        );
        clear_pick_transition(&journal, "shan", "山", "shui", "水").unwrap();
        assert_eq!(
            record_pick_transition(&journal, "shan", "山", "shui", "水").unwrap(),
            1
        );
        assert_eq!(count(&journal, "SELECT count(*) FROM pick_transitions"), 2);
    }

    #[test]
    fn a_new_pair_prunes_the_oldest_past_the_cap() {
        let dir = Dir::new();
        let journal = dir.journal();
        record_pick_transition(&journal, "a", "甲", "b", "乙").unwrap();
        let connection = rusqlite::Connection::open(&journal).unwrap();
        // Older than anything written now, one row past the cap.
        connection
            .execute_batch(&format!(
                "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<{MAX_PICK_TRANSITIONS}) INSERT INTO pick_transitions(previous_key,previous_value,key,value,count,updated_at) SELECT 'p'||i,'x','k','y',1,1000+i FROM n;"
            ))
            .unwrap();
        drop(connection);
        let total = (MAX_PICK_TRANSITIONS + 1) as i64;
        assert_eq!(
            count(&journal, "SELECT count(*) FROM pick_transitions"),
            total
        );
        // An existing pair never prunes.
        record_pick_transition(&journal, "a", "甲", "b", "乙").unwrap();
        assert_eq!(
            count(&journal, "SELECT count(*) FROM pick_transitions"),
            total
        );
        record_pick_transition(&journal, "c", "丙", "d", "丁").unwrap();
        assert_eq!(
            count(&journal, "SELECT count(*) FROM pick_transitions"),
            total,
            "the new row did not push the oldest one out"
        );
        assert_eq!(
            count(
                &journal,
                "SELECT count(*) FROM pick_transitions WHERE previous_key='p1'"
            ),
            0
        );
    }
}
