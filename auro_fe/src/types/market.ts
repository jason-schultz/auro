export interface OandaInstrument {
    name: string;
    displayName: string;
    type: string;
}

export interface InstrumentsResponse {
    instruments: OandaInstrument[];
    count: number;
}
