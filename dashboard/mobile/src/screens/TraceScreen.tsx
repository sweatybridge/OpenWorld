import { StyleSheet, Text } from "react-native";
import { Card, EmptyState, Scroll } from "../components";
import { TurnTraceTable } from "../components/TurnTrace";
import { colors } from "../lib/theme";
import type { TraceScreenProps } from "../nav/types";

type Props = TraceScreenProps;

// Full turn trace for any message id. The server resolves the turn's trigger, so
// this works from a user, assistant, or tool message alike.
export function TraceScreen({ route }: Props) {
  const messageId = Number(route.params.messageId);
  return (
    <Scroll>
      <Text style={s.h1}>Turn trace · msg #{route.params.messageId}</Text>
      {Number.isFinite(messageId) ? (
        <Card title="Correlated instances">
          <TurnTraceTable messageId={messageId} />
        </Card>
      ) : (
        <EmptyState>Bad message id.</EmptyState>
      )}
    </Scroll>
  );
}

const s = StyleSheet.create({
  h1: { fontSize: 20, fontWeight: "700", color: colors.text, marginBottom: 12 },
});
