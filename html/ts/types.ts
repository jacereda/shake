// Stuff that Shake generates and injects in

// The version of Shake
declare const version: string;

/////////////////////////////////////////////////////////////////////
// PROFILE DATA

declare const profileRaw: ProfileRaw[];

type timestamp = int;

interface Trace {
    command: string;
    start: seconds;
    stop: seconds;
}

interface Profile {
    name: string; // Name of the thing I built
    execution: seconds; // Seconds I took to execute
    built: timestamp; // Timestamp at which I was built
    changed: timestamp; // Timestamp at which I last changed
    depends: int[]; // Which 0-based indexes I depended on (always lower than my index)
    traces: Trace[]; // List of traces
}

type TraceRaw =
    [ string
    , seconds
    , seconds
    ];

type ProfileRaw =
    [ string
    , seconds
    , timestamp
    , timestamp
    , int[] // Optional
    , TraceRaw[] // Optional
    ];


/////////////////////////////////////////////////////////////////////
// PROGRESS DATA

declare const progress: Array<{name: string, values: Progress[]}>;

interface Progress {
    idealSecs: number;
    idealPerc: number;
    actualSecs: number;
    actualPerc: number;
}