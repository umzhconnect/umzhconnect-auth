package org.umzhconnect.keycloak;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.keycloak.OAuth2Constants;
import org.keycloak.representations.idm.ClientPolicyExecutorConfigurationRepresentation;
import org.keycloak.services.clientpolicy.ClientPolicyContext;
import org.keycloak.services.clientpolicy.ClientPolicyEvent;
import org.keycloak.services.clientpolicy.ClientPolicyException;
import org.keycloak.services.clientpolicy.context.ServiceAccountTokenRequestContext;
import org.keycloak.services.clientpolicy.executor.ClientPolicyExecutorProvider;

import java.io.IOException;
import java.util.Iterator;
import java.util.Set;

/**
 * Client policy executor for the UMZH Connect context: an RFC 9396
 * authorization_details entry of type {@link #TYPE} whose {@code identifier}
 * names the workflow root (e.g. "ServiceRequest/sr-123").
 *
 * On every client_credentials token request it
 * <ul>
 *   <li>rejects invalid authorization_details with {@code invalid_authorization_details}
 *       (RFC 9396 §5): malformed JSON (including trailing content), an unknown
 *       type, unknown or wrongly typed fields, a missing identifier, or more
 *       than one context;</li>
 *   <li>stores the granted context, normalised to {@code [{type, identifier}]},
 *       in the user session note {@link #NOTE}. Keycloak's built-in
 *       oidc-usersessionmodel-note-mapper copies it into the access token and
 *       the token response (terraform/clients.tf).</li>
 * </ul>
 *
 * A client policy is used because Keycloak 26.x does not run its RAR
 * AuthorizationDetailsProcessor SPI for the client_credentials grant, and a
 * protocol mapper cannot fail the request. The client-policy event fires
 * before Keycloak builds the token, so the note is in place for the mapper.
 *
 * The identifier's content is deliberately not checked — the Resource Server
 * resolves it against its own workflow data.
 */
public class ContextExecutor
        implements ClientPolicyExecutorProvider<ClientPolicyExecutorConfigurationRepresentation> {

    public static final String TYPE = "http://fhir.ch/ig/ch-umzh-connect/context";

    /** User session note read by the session note mapper. */
    public static final String NOTE = "umzh.context";

    private static final String ERROR = "invalid_authorization_details";

    /** The only fields the IG defines for the context type. */
    private static final Set<String> FIELDS = Set.of("type", "identifier");

    private static final ObjectMapper JSON = new ObjectMapper()
            .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS);

    @Override
    public String getProviderId() {
        return ContextExecutorFactory.PROVIDER_ID;
    }

    @Override
    public void executeOnEvent(ClientPolicyContext context) throws ClientPolicyException {
        if (context.getEvent() != ClientPolicyEvent.SERVICE_ACCOUNT_TOKEN_REQUEST) return;

        ServiceAccountTokenRequestContext request = (ServiceAccountTokenRequestContext) context;
        String raw = request.getParams().getFirst(OAuth2Constants.AUTHORIZATION_DETAILS);
        if (raw == null || raw.isBlank()) return;

        String normalised = JSON.createArrayNode()
                .add(JSON.createObjectNode().put("type", TYPE).put("identifier", identifier(raw)))
                .toString();
        request.getClientSession().getUserSession().setNote(NOTE, normalised);
    }

    /** Validates the raw parameter and returns the single context's identifier. */
    private static String identifier(String raw) throws ClientPolicyException {
        JsonNode root;
        try {
            root = JSON.readTree(raw);
        } catch (IOException e) {
            throw invalid("authorization_details is not valid JSON");
        }
        if (root == null || !root.isArray() || root.isEmpty()) {
            throw invalid("authorization_details must be a non-empty JSON array");
        }
        if (root.size() > 1) {
            throw invalid("a token request carries at most one context");
        }

        JsonNode entry = root.get(0);
        if (!entry.isObject()) {
            throw invalid("authorization_details entry must be a JSON object");
        }
        JsonNode type = entry.get("type");
        if (type == null || !type.isTextual()) {
            throw invalid("authorization_details entry is missing type");
        }
        if (!TYPE.equals(type.asText())) {
            throw invalid("unsupported authorization_details type: " + type.asText());
        }
        for (Iterator<String> names = entry.fieldNames(); names.hasNext(); ) {
            String name = names.next();
            if (!FIELDS.contains(name)) {
                throw invalid("unknown field in context entry: " + name);
            }
        }
        JsonNode id = entry.get("identifier");
        if (id == null || !id.isTextual() || id.asText().isBlank()) {
            throw invalid("context entry is missing identifier");
        }
        return id.asText();
    }

    private static ClientPolicyException invalid(String detail) {
        return new ClientPolicyException(ERROR, detail);
    }
}
