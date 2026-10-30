package org.umzhconnect.keycloak;

import org.jboss.logging.Logger;
import org.keycloak.models.ClientSessionContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ProtocolMapperModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.protocol.oidc.mappers.AbstractOIDCProtocolMapper;
import org.keycloak.protocol.oidc.mappers.OIDCAccessTokenMapper;
import org.keycloak.protocol.oidc.mappers.OIDCAccessTokenResponseMapper;
import org.keycloak.provider.ProviderConfigProperty;
import org.keycloak.representations.AccessTokenResponse;
import org.keycloak.representations.AuthorizationDetailsJSONRepresentation;
import org.keycloak.representations.IDToken;

import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/**
 * Carries the granted UMZH Connect context (RFC 9396 authorization_details,
 * type {@value ContextAuthorizationDetails#TYPE}) as a top-level
 * {@code authorization_details} claim in the access token (RFC 9396 §9.1) and
 * in the token response (RFC 9396 §7), normalised to {@code [{type, identifier}]}.
 *
 * Reads the raw session note directly: Keycloak 26.x does not populate
 * AuthorizationRequestContext with custom authorization_details types for the
 * client_credentials flow (only built-in SMART scope entries appear there).
 *
 * Invalid requests are rejected earlier by {@link ContextExecutor}; if that
 * client policy is not configured, this mapper emits no context and logs a
 * warning instead.
 */
public class ContextMapper extends AbstractOIDCProtocolMapper
        implements OIDCAccessTokenMapper, OIDCAccessTokenResponseMapper {

    public static final String PROVIDER_ID = "umzh-context-mapper";

    private static final Logger LOG = Logger.getLogger(ContextMapper.class);

    private static final String[] NOTE_KEYS = {
        "authorization_details",
        "client_request_param_authorization_details",
    };

    @Override public String getId()              { return PROVIDER_ID; }
    @Override public String getDisplayCategory() { return TOKEN_MAPPER_CATEGORY; }
    @Override public String getDisplayType()     { return "UMZH Context (RFC 9396)"; }

    @Override
    public String getHelpText() {
        return "Maps the RFC 9396 authorization_details context (type "
             + ContextAuthorizationDetails.TYPE + ") to an authorization_details claim "
             + "in the access token and the token response.";
    }

    @Override
    public List<ProviderConfigProperty> getConfigProperties() {
        return Collections.emptyList();
    }

    @Override
    protected void setClaim(IDToken token, ProtocolMapperModel model,
                            UserSessionModel userSession,
                            KeycloakSession session,
                            ClientSessionContext clientSessionCtx) {
        context(clientSessionCtx).ifPresent(ctx ->
            token.getOtherClaims().put(ContextAuthorizationDetails.PARAM, List.of(ctx)));
    }

    @Override
    protected void setClaim(AccessTokenResponse response, ProtocolMapperModel model,
                            UserSessionModel userSession,
                            KeycloakSession session,
                            ClientSessionContext clientSessionCtx) {
        context(clientSessionCtx).ifPresent(ctx -> {
            AuthorizationDetailsJSONRepresentation detail = new AuthorizationDetailsJSONRepresentation();
            detail.setType(ctx.get("type"));
            detail.setIdentifier(ctx.get("identifier"));
            response.setAuthorizationDetails(List.of(detail));
        });
    }

    private Optional<Map<String, String>> context(ClientSessionContext clientSessionCtx) {
        // Keycloak 26.x does not populate AuthorizationRequestContext with custom
        // authorization_details types for the client_credentials flow — only built-in
        // SMART scope entries appear there.  Read the raw session note instead.
        String raw = null;
        for (String key : NOTE_KEYS) {
            raw = clientSessionCtx.getClientSession().getNote(key);
            if (raw != null && !raw.isBlank()) break;
        }
        try {
            return ContextAuthorizationDetails.parse(raw);
        } catch (ContextAuthorizationDetails.InvalidException e) {
            LOG.warnf("Ignoring invalid authorization_details for client %s: %s "
                    + "(is the umzh-context-executor client policy configured?)",
                    clientSessionCtx.getClientSession().getClient().getClientId(), e.getMessage());
            return Optional.empty();
        }
    }
}
