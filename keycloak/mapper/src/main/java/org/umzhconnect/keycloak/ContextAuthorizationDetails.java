package org.umzhconnect.keycloak;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.io.IOException;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Optional;

/**
 * The UMZH Connect context: an RFC 9396 authorization_details entry of type
 * {@link #TYPE} whose {@code identifier} names the workflow root
 * (e.g. "ServiceRequest/sr-123"). Shared by {@link ContextExecutor}, which
 * rejects invalid token requests, and {@link ContextMapper}, which writes the
 * granted context into the token and the token response.
 *
 * The identifier's content is deliberately not checked here — the Resource
 * Server resolves it against its own workflow data.
 */
public final class ContextAuthorizationDetails {

    public static final String TYPE = "http://fhir.ch/ig/ch-umzh-connect/context";

    /** Token request parameter and access token claim name (RFC 9396 §2, §9.1). */
    public static final String PARAM = "authorization_details";

    /** RFC 9396 §5 error code. */
    public static final String ERROR = "invalid_authorization_details";

    private static final ObjectMapper JSON = new ObjectMapper();

    private ContextAuthorizationDetails() {}

    /** The request violates the IG's rules; the message is safe to return to the client. */
    public static class InvalidException extends Exception {
        public InvalidException(String message) {
            super(message);
        }
    }

    /**
     * Parses the raw authorization_details parameter.
     *
     * @return empty when the parameter is absent; otherwise the single context,
     *         normalised to {@code {type, identifier}}
     * @throws InvalidException for malformed JSON, an unknown type, a missing
     *         identifier, or more than one context
     */
    public static Optional<Map<String, String>> parse(String raw) throws InvalidException {
        if (raw == null || raw.isBlank()) return Optional.empty();

        JsonNode root;
        try {
            root = JSON.readTree(raw);
        } catch (IOException e) {
            throw new InvalidException("authorization_details is not valid JSON");
        }
        if (root == null || !root.isArray() || root.isEmpty()) {
            throw new InvalidException("authorization_details must be a non-empty JSON array");
        }

        String identifier = null;
        for (JsonNode entry : root) {
            if (!entry.isObject()) {
                throw new InvalidException("each authorization_details entry must be a JSON object");
            }
            JsonNode type = entry.get("type");
            if (type == null || !type.isTextual()) {
                throw new InvalidException("authorization_details entry is missing type");
            }
            if (!TYPE.equals(type.asText())) {
                throw new InvalidException("unsupported authorization_details type: " + type.asText());
            }
            if (identifier != null) {
                throw new InvalidException("a token request carries at most one context");
            }
            JsonNode id = entry.get("identifier");
            if (id == null || !id.isTextual() || id.asText().isBlank()) {
                throw new InvalidException("context entry is missing identifier");
            }
            identifier = id.asText();
        }
        return Optional.of(normalised(identifier));
    }

    /** The context as it appears in the access token and the token response. */
    public static Map<String, String> normalised(String identifier) {
        Map<String, String> entry = new LinkedHashMap<>();
        entry.put("type", TYPE);
        entry.put("identifier", identifier);
        return entry;
    }
}
