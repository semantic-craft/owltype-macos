const SLASH_SYMBOLS: &[&str] = &["、", "/", "／", "÷"];
const ANGLE_SYMBOLS: &[&str] = &["《", "〈", "<", "「", "“"];

pub(crate) fn candidates_for(trigger: char) -> Option<&'static [&'static str]> {
    match trigger {
        '/' => Some(SLASH_SYMBOLS),
        '<' => Some(ANGLE_SYMBOLS),
        _ => None,
    }
}

#[derive(Debug, Clone)]
pub(crate) struct PunctuationMenu {
    trigger: char,
    highlighted: usize,
    generation: u64,
}

impl PunctuationMenu {
    pub(crate) fn new(trigger: char, generation: u64) -> Option<Self> {
        candidates_for(trigger)?;
        Some(Self {
            trigger,
            highlighted: 0,
            generation,
        })
    }

    pub(crate) fn trigger(&self) -> char {
        self.trigger
    }

    pub(crate) fn generation(&self) -> u64 {
        self.generation
    }

    pub(crate) fn set_generation(&mut self, generation: u64) {
        self.generation = generation;
    }

    pub(crate) fn candidates(&self) -> &'static [&'static str] {
        candidates_for(self.trigger).expect("punctuation menu trigger was validated")
    }

    pub(crate) fn selected(&self) -> &'static str {
        self.candidates()[self.highlighted]
    }

    pub(crate) fn highlighted(&self) -> usize {
        self.highlighted
    }

    pub(crate) fn cycle(&mut self) {
        self.highlighted = (self.highlighted + 1) % self.candidates().len();
    }

    pub(crate) fn move_highlight(&mut self, delta: i32) -> bool {
        let last = self.candidates().len() - 1;
        let next = if delta < 0 {
            self.highlighted
                .saturating_sub(delta.unsigned_abs() as usize)
        } else {
            self.highlighted.saturating_add(delta as usize).min(last)
        };
        let changed = next != self.highlighted;
        self.highlighted = next;
        changed
    }

    pub(crate) fn page(&self, page_size: usize) -> usize {
        self.highlighted / page_size.max(1)
    }

    pub(crate) fn page_count(&self, page_size: usize) -> usize {
        self.candidates().len().div_ceil(page_size.max(1))
    }

    pub(crate) fn set_page(&mut self, page: usize, page_size: usize) -> bool {
        let page = page.min(self.page_count(page_size).saturating_sub(1));
        let next = page * page_size.max(1);
        let changed = next != self.highlighted;
        self.highlighted = next;
        changed
    }

    pub(crate) fn candidate(&self, index: usize) -> Option<&'static str> {
        self.candidates().get(index).copied()
    }
}
