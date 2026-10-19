export interface ServiceOperationDetails {
  summary: string;
  data: unknown;
  includeResponse: boolean;
  databaseName?: string;
  collection?: string;
  driverRequestId?: number;
  method?: string;
  path?: string;
  channel?: string;
  status?: number | null;
  purpose?: string;
  channelCount?: number;
  responseSnapshot?: (value: unknown) => unknown;
  errorSnapshot?: (value: unknown) => unknown;
}
