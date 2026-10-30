package org.umzhconnect.keycloak;

import org.keycloak.Config;
import org.keycloak.models.KeycloakSession;
import org.keycloak.protocol.oidc.rar.AuthorizationDetailsProcessor;
import org.keycloak.protocol.oidc.rar.AuthorizationDetailsProcessorFactory;
import org.keycloak.representations.AuthorizationDetailsJSONRepresentation;
import org.keycloak.util.AuthorizationDetailsParser;

public class ContextProcessorFactory implements AuthorizationDetailsProcessorFactory {

    // Keycloak looks processors up by factory ID, not by getSupportedType(), so
    // the ID must be the authorization_details type itself.
    public static final String PROVIDER_ID = ContextAuthorizationDetails.TYPE;

    @Override public String getId() { return PROVIDER_ID; }

    @Override
    public AuthorizationDetailsProcessor<?> create(KeycloakSession session) {
        return new ContextProcessor();
    }

    @Override
    public void init(Config.Scope config) {
        // Before sending the token response, Keycloak converts each entry with
        // asSubtype(), which fails for a type without a registered parser. The
        // context needs no subtype: pass the entry through unchanged.
        AuthorizationDetailsParser.registerParser(ContextAuthorizationDetails.TYPE, new AuthorizationDetailsParser() {
            @Override
            public <T extends AuthorizationDetailsJSONRepresentation> T asSubtype(
                    AuthorizationDetailsJSONRepresentation detail, Class<T> clazz) {
                return clazz.cast(detail);
            }
        });
    }
}
